const std = @import("std");
const zlog = @import("zlog");
const flint = @import("flint.zig");
const utils = @import("utils.zig");

const major = 1;
const minor = 0;
const patch = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    try zlog.initGlobalLogger(
        .INFO,
        true,
        null,
        null,
        null,
        allocator,
    );
    defer zlog.deinitGlobalLogger();

    try utils.setAbortSignalHandler();

    zlog.info("Flint v{d}.{d}.{d}", .{ major, minor, patch });

    var args_iter = std.process.args();
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    while (args_iter.next()) |arg| {
        try args.append(arg);
    }

    if (args.items.len < 2) {
        zlog.err("Usage: flint <run|watch> <task>", .{});
        std.process.exit(1);
    }

    const command = args.items[1];
    if (!std.mem.eql(u8, command, "run") and !std.mem.eql(u8, command, "watch")) {
        zlog.err("Invalid command '{s}'. Expected 'run' or 'watch'", .{command});
        std.process.exit(1);
    }

    const task = if (args.items.len > 2) args.items[2] else "";

    var flint_inst = try flint.parseTasks(allocator, "flint.zon", command);

    if (flint_inst.tasks.get(task)) |t| {
        zlog.debug("Running command '{s}' with task '{s}'", .{ command, t.cmd });
        if (std.mem.eql(u8, command, "run")) {
            try runCommand(allocator, t.cmd);
        } else {
            try runCommand(allocator, t.cmd);
            const debounce_ns = 200_000_000; // 200ms
            var last_run_time: i128 = 0;

            while (true) {
                if (utils.shouldExit()) break;

                std.Thread.sleep(100_000);

                if (flint_inst.file_changed.swap(false, .seq_cst)) {
                    zlog.info("File changed!", .{});
                    const now = std.time.nanoTimestamp();
                    if (now - last_run_time > debounce_ns) {
                        try runCommand(allocator, t.cmd);
                        last_run_time = now;
                    }
                }
            }
        }
    } else {
        zlog.err("Task '{s}' not found", .{task});
        std.process.exit(1);
    }

    flint_inst.deinit();
}

fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) !void {
    // const shell = "/bin/sh";
    // const shell_args = "-c";

    // const merge_cmd = try std.fmt.allocPrint(allocator, "{s} 2>&1", .{cmd});
    // defer allocator.free(merge_cmd);

    // const args = [_][]const u8{ shell, shell_args, merge_cmd };

    const args = [_][]const u8{ "script", "-q", "-c", cmd, "/dev/null" };
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (child.stdout) |stdout| {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = try stdout.read(&buf);
            if (n == 0) break;
            _ = try std.io.getStdOut().writeAll(buf[0..n]);
        }
    }

    if (child.stderr) |stderr| {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = try stderr.read(&buf);
            if (n == 0) break;
            _ = try std.io.getStdErr().writeAll(buf[0..n]);
        }
    }

    _ = try child.wait();
}
