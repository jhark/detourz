const std = @import("std");
const detours = @import("detourz");
const windows = std.os.windows;

const log = std.log.scoped(.exports);

pub fn run(allocator: std.mem.Allocator, module_path: []const u8) !void {
    const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, module_path);
    defer allocator.free(wide_path);

    const module_handle = try windows.LoadLibraryExW(
        wide_path.ptr,
        // .load_library_as_image_resource,
        .dont_resolve_dll_references,
    );
    defer _ = windows.FreeLibrary(module_handle);

    var stdout = std.io.getStdOut().writer();

    const ExportContext = struct {
        module_handle: windows.HMODULE,
        stdout: std.fs.File.Writer,
    };

    var context = ExportContext{
        .module_handle = module_handle,
        .stdout = stdout,
    };

    stdout.print("{s:>8} {s:<10} {s:<8}\n", .{ "Ordinal", "RVA", "Name" }) catch return;

    const export_callback = struct {
        fn callback(
            pContext: ?*anyopaque,
            nOrdinal: windows.ULONG,
            pszName: ?[*:0]const u8,
            pCode: ?*anyopaque,
        ) callconv(.C) windows.BOOL {
            const ctx = @as(*ExportContext, @ptrCast(@alignCast(pContext)));

            ctx.stdout.print("{d:>8}", .{nOrdinal}) catch return windows.FALSE;

            if (pCode) |addr| {
                const module_base = @intFromPtr(ctx.module_handle);
                const addr_value = @intFromPtr(addr);
                const rva = if (addr_value > module_base) addr_value - module_base else addr_value;
                ctx.stdout.print(" 0x{x:0>8}", .{rva}) catch return windows.FALSE;
            } else {
                ctx.stdout.print(" {s:<10}", .{"<none>"}) catch return windows.FALSE;
            }

            const name_str = if (pszName) |n| n else "<none>";
            ctx.stdout.print(" {s}\n", .{name_str}) catch return windows.FALSE;

            return windows.TRUE;
        }
    }.callback;

    detours.enumerateExports(module_handle, &context, export_callback) catch |err| {
        switch (err) {
            error.ExeMarkedInvalid => {
                log.err("Failed to enumerate exports: No export section, or not a valid PE file.", .{});
                std.process.exit(1);
                return;
            },
            else => {
                log.err("Failed to enumerate exports: {}", .{err});
                return err;
            },
        }
    };
}
