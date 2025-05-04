const std = @import("std");
const builtin = @import("builtin");
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

    var clean_args = std.ArrayList([]const u8).init(allocator);
    defer clean_args.deinit();

    for (args.items[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            continue;
        } else {
            try clean_args.append(arg);
        }
    }

    const command = clean_args.items[0];
    if (!std.mem.eql(u8, command, "run") and !std.mem.eql(u8, command, "watch")) {
        zlog.err("Invalid command '{s}'. Expected 'run' or 'watch'", .{command});
        std.process.exit(1);
    }

    const task = if (clean_args.items.len > 1) clean_args.items[1] else "";

    var flint_inst = try flint.parseTasks(
        allocator,
        "flint.zon",
        command,
    );

    if (flint_inst.tasks.get(task)) |t| {
        zlog.debug("Running command '{s}' with task '{s}'", .{ command, t.cmd });
        if (std.mem.eql(u8, command, "run")) {
            try runCommand(allocator, t.cmd);
        } else {
            zlog.info("Watching {d} files for changes", .{flint_inst.watcher.?.files.count()});
            try runCommand(allocator, t.cmd);
            const debounce_ns = 200_000_000; // 200ms
            var last_run_time: i128 = 0;

            try flint_inst.startWatcherThread(allocator);

            while (true) {
                if (utils.shouldExit()) break;

                std.Thread.sleep(10_000);

                if (flint_inst.file_changed.swap(false, .seq_cst)) {
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
    zlog.info("Running command '{s}'", .{cmd});

    const args_slice = if (builtin.os.tag == .macos)
        &[_][]const u8{ "script", "-q", "/dev/null", "/bin/sh", "-c", cmd }
    else
        &[_][]const u8{ "sh", "-c", cmd };

    var child = std.process.Child.init(args_slice, allocator);
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
