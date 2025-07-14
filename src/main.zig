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

    try zlog.initGlobalLogger(log_level, true, null, null, null, allocator);
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
    if (std.mem.eql(u8, command, "version")) {
        return;
    }
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
            try runTaskAndDeps(t);
        } else {
            zlog.info("Watching {d} files for changes", .{t.watcher.?.files.count()});
            // Spin up thread for watcher

            var watcher_thread = try std.Thread.spawn(.{
                .allocator = allocator,
            }, watcherThread, .{t});

            var run_thread = std.Thread.spawn(.{ .allocator = allocator }, runTaskAndDeps, .{t}) catch |e| {
                zlog.err("Failed to spawn watcher thread: {any}", .{e});
                std.process.exit(1);
            };

            // const debounce_ns = 200_000_000; // 200ms
            const debounce_ns = 100_000; // 200ms
            var last_run_time: i128 = 0;
            while (true) {
                if (utils.shouldExit()) break;
                if (flint.watcher_ready.load(.seq_cst)) {
                    zlog.info("File change detected!", .{});
                    const now = std.time.nanoTimestamp();
                    if (now - last_run_time > debounce_ns) {
                        const killed = killRunningProcess();
                        if (killed) {
                            run_thread.detach();
                        }

                        run_thread = std.Thread.spawn(.{ .allocator = allocator }, runTaskAndDeps, .{t}) catch |e| {
                            zlog.err("Failed to spawn watcher thread: {any}", .{e});
                            std.process.exit(1);
                        };
                        last_run_time = now;
                        flint.watcher_ready.store(false, .seq_cst);
                    }
                }
            }
            zlog.info("Shutting down...", .{});
            _ = killRunningProcess();
            zlog.info("Running process killed", .{});
            watcher_thread = undefined;
            run_thread.detach();
        }
    } else {
        zlog.err("Task '{s}' not found", .{task});
        std.process.exit(1);
    }

    flint_inst.deinit();
}

const RunningProcess = struct {
    child: ?*std.process.Child = null,
    mutex: std.Thread.Mutex = .{},
};

var running_process = RunningProcess{};

fn runCommandInternal(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    output_behavior: std.process.Child.StdIo,
) !void {
    zlog.info("Running command '{s}'", .{cmd});

    const args_slice = if (builtin.os.tag == .macos)
        &[_][]const u8{ "script", "-q", "/dev/null", "/bin/sh", "-c", cmd }
    else
        &[_][]const u8{ "sh", "-c", cmd };

    var child = try allocator.create(std.process.Child);
    child.* = std.process.Child.init(args_slice, allocator);
    child.stdout_behavior = output_behavior;
    child.stderr_behavior = output_behavior;

    try child.spawn();

    running_process.mutex.lock();
    zlog.debug("Set child process", .{});
    running_process.child = child;
    running_process.mutex.unlock();
}

fn killRunningProcess() bool {
    var result = false;
    zlog.info("Locking running process mutex", .{});
    running_process.mutex.lock();
    if (running_process.child) |child| {
        zlog.info("Killing running process", .{});
        _ = child.kill() catch {};
        zlog.info("Process killed", .{});
        // Optionally, you can also wait and free here if you want to clean up
        // _ = child.wait() catch {};
        // allocator.destroy(child);
        running_process.child = null;
        result = true;
    }
    running_process.mutex.unlock();
    zlog.info("Running process mutex unlocked", .{});
    return result;
}

fn runTaskAndDeps(task: *flint.Task) !void {
    const allocator = std.heap.page_allocator;
    if (task.deps_tasks.len == 0) {
        try runCommandInternal(allocator, task.cmd orelse return, .Inherit);
        if (running_process.child) |child| {
            const term = try child.wait();
            if (term.Exited != 0) {
                // Dependency failed
                zlog.err("Dependency '{s}' failed with exit code {d}", .{ task.name, term.Exited });
                return;
            }
            running_process.mutex.lock();
            running_process.child = null;
            running_process.mutex.unlock();
            zlog.info("Task '{s}' finished successfully", .{task.name});
        }
    }
    for (task.deps_tasks, 0..) |dep, idx| {
        if (dep.cmd) |cmd| {
            if (idx != task.deps_tasks.len - 1) {
                // Wait for dependency to finish before running the next one
                // try runCommandInternal(allocator, cmd, .Pipe);
                try runCommandInternal(allocator, cmd, .Inherit);

                if (running_process.child) |child| {
                    zlog.debug("Waiting for dependency '{s}' to finish", .{dep.name});
                    // if (child.stdout) |stdout| {
                    //     var buf: [1024]u8 = undefined;
                    //     while (true) {
                    //         const n = try stdout.read(&buf);
                    //         if (n == 0) break;
                    //         _ = try std.io.getStdOut().writeAll(buf[0..n]);
                    //     }
                    // }
                    //
                    // if (child.stderr) |stderr| {
                    //     var buf: [1024]u8 = undefined;
                    //     while (true) {
                    //         const n = try stderr.read(&buf);
                    //         if (n == 0) break;
                    //         _ = try std.io.getStdErr().writeAll(buf[0..n]);
                    //     }
                    // }
                    const term = try child.wait();
                    if (term.Exited != 0) {
                        // Dependency failed
                        zlog.err("Dependency '{s}' failed with exit code {d}", .{ dep.name, term.Exited });
                        return;
                    }
                    running_process.mutex.lock();
                    running_process.child = null;
                    running_process.mutex.unlock();
                    zlog.debug("Dependency '{s}' finished", .{dep.name});
                }
            } else {
                try runCommandInternal(allocator, cmd, .Inherit);
            }
        }
    }
}

fn watcherThread(t: *flint.Task) !void {
    zlog.info("Starting watcher thread", .{});
    while (true) {
        if (utils.shouldExit()) {
            zlog.info("Killing watcher thread", .{});
            break;
        }
        // flint.watchUntilUpdate(t.watcher.?) catch {
        flint.watchUnilUpdateFswatch(t.watcher.?) catch |e| {
            zlog.err("Watcher thread failed: {any}", .{e});
            std.Thread.sleep(std.time.ns_per_s * 0.1);
            continue;
        };
        flint.watcher_ready.store(true, .seq_cst);
    }

    zlog.info("Returning from watcher thread", .{});
}
