const std = @import("std");
const builtin = @import("builtin");

pub var shouldExitValue = std.atomic.Value(bool).init(false);

pub fn setAbortSignalHandler() !void {
    if (builtin.os.tag == .windows) {
        const handler_routine = struct {
            fn handler_routine(dwCtrlType: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) void {
                if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
                    shouldExitValue.store(true, .seq_cst);
                    return std.os.windows.TRUE;
                } else {
                    return std.os.windows.FALSE;
                }
            }
        }.handler_routine;
        try std.os.windows.SetConsoleCtrlHandler(handler_routine, true);
    } else {
        const internal_handler = struct {
            fn internalHandler(sig: c_int) callconv(.c) void {
                if (sig == std.posix.SIG.INT) {
                    std.debug.print("Shutting down...\n", .{});
                    shouldExitValue.store(true, .seq_cst);
                }
            }
        }.internalHandler;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = internal_handler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}

pub fn shouldExit() bool {
    return shouldExitValue.load(.seq_cst);
}
