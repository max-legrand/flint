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
            const debounce_ns = 100_000; // 200ms
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
    if (builtin.os.tag == .macos) {
        // 1. Create a temp file path (don't open it yet)
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/flint-script-XXXXXX", .{});

        // 2. Build the args: script -q <tmpfile> /bin/sh -c <cmd>
        var args = [_][]const u8{ "script", "-q", tmp_path, "/bin/sh", "-c", cmd };
        var child = std.process.Child.init(&args, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        _ = try child.wait();

        // 3. Open and print the temp file
        var tmp_file = try std.fs.cwd().openFile(tmp_path, .{});
        defer tmp_file.close();

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try tmp_file.read(&buf);
            if (n == 0) break;
            _ = try std.io.getStdOut().writeAll(buf[0..n]);
        }

        // 4. Delete the temp file
        std.fs.cwd().deleteFile(tmp_path) catch {};
    } else {
        // Linux and others: use script -q -c <cmd> /dev/null
        var args = [_][]const u8{ "script", "-q", "-c", cmd, "/dev/null" };
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
}
