const std = @import("std");
const builtin = @import("builtin");
const zlog = @import("zlog");
const cmd = @import("cmd.zig");
const utils = @import("utils.zig");
const tasks = @import("tasks.zig");
const watcher = @import("watcher.zig");

const config = @import("config");

const major = 1;
const minor = 1;
const patch = 0;

const CommandType = enum { run, watch };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try utils.setAbortSignalHandler();

    var verbose = config.verbose;
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
    const command_type = if (std.mem.eql(u8, command, "run")) CommandType.run else CommandType.watch;

    // Parse the tasks
    var flint = try tasks.parseTasks(allocator);
    defer flint.deinit(allocator);
    zlog.debug("Flint config parsed", .{});

    const task_name = if (clean_args.items.len > 1) clean_args.items[1] else "";

    // If task not registered, fail
    var task: ?tasks.Task = null;
    for (flint.tasks) |t| {
        if (std.mem.eql(u8, t.name, task_name)) {
            task = t.*;
            break;
        }
    }
    if (task == null) {
        zlog.err("Task '{s}' not found", .{task_name});
        std.process.exit(1);
    }

    if (config.verbose) {
        zlog.debug("Command: {s} {s}", .{ @tagName(command_type), task.?.name });
    }

    switch (command_type) {
        .run => {
            try runTaskAndDeps(allocator, flint, &task.?);
            return;
        },
        .watch => {
            // Create watcher thread.
            const watcher_thread = try std.Thread.spawn(.{ .allocator = allocator }, watcher.spawnWatcher, .{ task.?, false });
            const debounce_ns = 100_000; // 200ms
            var last_run_time: i128 = 0;

            var main_task: ?std.process.Child = null;
            if (task.?.keep_alive) {
                if (config.verbose) {
                    zlog.debug("Running task in keep-alive mode", .{});
                }
                main_task = runTaskAsync(allocator, flint, &task.?) catch |err| switch (err) {
                    error.CommandFailed => null,
                    else => {
                        return err;
                    },
                };
            } else {
                runTaskAndDeps(allocator, flint, &task.?) catch |err| {
                    switch (err) {
                        error.CommandFailed => {},
                        else => {
                            return err;
                        },
                    }
                };
            }

            while (!utils.shouldExit()) {
                if (config.verbose) {
                    zlog.debug("Waiting for file change", .{});
                }
                if (watcher.watcher_ready.load(.seq_cst)) {
                    zlog.info("File change detected!", .{});
                    const now = std.time.nanoTimestamp();
                    if (now - last_run_time > debounce_ns) {
                        // Kill running process & re-run
                        if (main_task) |*t| {
                            _ = t.kill() catch |err| {
                                zlog.err("Failed to kill running process: {any}", .{err});
                            };
                        }
                        last_run_time = now;
                        watcher.watcher_ready.store(false, .seq_cst);
                        if (task.?.keep_alive) {
                            main_task = runTaskAsync(allocator, flint, &task.?) catch |err| switch (err) {
                                error.CommandFailed => null,
                                else => {
                                    return err;
                                },
                            };
                        } else {
                            runTaskAndDeps(allocator, flint, &task.?) catch |err| switch (err) {
                                error.CommandFailed => {},
                                else => {
                                    return err;
                                },
                            };
                        }
                    }
                }
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            if (main_task) |*t| {
                _ = t.kill() catch |err| {
                    zlog.err("Failed to kill running process: {any}", .{err});
                };
            }
            watcher_thread.join();
        },
    }
}

fn runTaskAsync(allocator: std.mem.Allocator, flint: tasks.Flint, task: *tasks.Task) !std.process.Child {
    // First run the dependencies (synchronously)
    // Then run the task asynchronously
    if (task.deps) |deps| {
        for (deps) |dep| {
            const dep_task = flint.tasks_map.get(dep) orelse continue;
            zlog.info("Running dependency {s}", .{dep});
            runTaskAndDeps(allocator, flint, dep_task) catch |err| {
                return err;
            };
            zlog.info("Dependency {s} finished", .{dep});
        }
    }

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    var iter = std.mem.tokenizeScalar(u8, task.cmd, ' ');
    while (iter.next()) |arg| {
        try args.append(arg);
    }

    zlog.info("Running command: {s}", .{task.cmd});
    return try cmd.executeCommandAsync(allocator, args.items, task.cwd);
}

fn runTaskAndDeps(allocator: std.mem.Allocator, flint: tasks.Flint, task: *tasks.Task) !void {
    if (task.deps) |deps| {
        for (deps) |dep| {
            const dep_task = flint.tasks_map.get(dep) orelse continue;
            zlog.info("Running dependency {s}", .{dep});
            try runTaskAndDeps(allocator, flint, dep_task);
            zlog.info("Dependency {s} finished", .{dep});
        }
    }

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    var iter = std.mem.tokenizeScalar(u8, task.cmd, ' ');
    while (iter.next()) |arg| {
        try args.append(arg);
    }

    zlog.info("Running command: {s}", .{task.cmd});
    cmd.executeCommandSync(allocator, args.items, task.cwd) catch |err| {
        return err;
    };
    zlog.info("Command finished", .{});
}
