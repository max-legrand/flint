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

    try utils.setAbortSignalHandler();

    var verbose = false;
    var args_iter = std.process.args();
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        try args.append(arg);
    }

    const log_level: zlog.Logger.Level = if (verbose) .DEBUG else .INFO;

    try zlog.initGlobalLogger(
        log_level,
        true,
        null,
        null,
        null,
        allocator,
    );
    defer zlog.deinitGlobalLogger();
    zlog.info("Flint v{d}.{d}.{d}", .{ major, minor, patch });

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

    var flint_inst = flint.parseTasks(
        allocator,
        "flint.zon",
    ) catch |err| {
        switch (err) {
            error.TaskHasNoCommandOrDeps => {
                zlog.err("Task '{s}' has no command or dependencies", .{task});
                return err;
            },
            else => {
                return err;
            },
        }
    };

    if (flint_inst.tasks.get(task)) |t| {
        zlog.debug("Task Deps:", .{});
        for (t.deps_tasks) |dep| {
            if (dep.cmd) |cmd| {
                zlog.debug("  - {s}", .{cmd});
            }
        }
        if (std.mem.eql(u8, command, "run")) {
            try runTaskAndDeps(allocator, t);
        } else {
            zlog.info("Watching {d} files for changes", .{t.watcher.?.files.count()});
            runTaskAndDeps(allocator, t) catch {
                zlog.err("Task '{s}' failed", .{t.name});
            };
            const debounce_ns = 200_000_000; // 200ms
            var last_run_time: i128 = 0;

            try flint_inst.startWatcherThread(t, allocator);

            while (true) {
                if (utils.shouldExit()) break;

                std.Thread.sleep(10_000);

                if (flint_inst.file_changed.swap(false, .seq_cst)) {
                    const now = std.time.nanoTimestamp();
                    if (now - last_run_time > debounce_ns) {
                        runTaskAndDeps(allocator, t) catch {
                            zlog.err("Task '{s}' failed", .{t.name});
                        };
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

fn runCommandInternal(allocator: std.mem.Allocator, cmd: []const u8) !void {
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

    const result = try child.wait();
    if (result.Exited != 0) {
        return error.CommandFailed;
    }
}

fn runTaskAndDeps(allocator: std.mem.Allocator, task: *flint.Task) !void {
    if (task.deps_tasks.len == 0) {
        try runCommandInternal(allocator, task.cmd orelse return);
        return;
    }
    for (task.deps_tasks) |dep| {
        if (dep.cmd) |cmd| {
            try runCommandInternal(allocator, cmd);
        }
    }
}
