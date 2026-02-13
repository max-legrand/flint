const std = @import("std");
const config = @import("config");
const zlog = @import("zlog");
const tasks = @import("tasks.zig");
const utils = @import("utils.zig");

const string = []const u8;

/// Store the fswatch pid directly so the signal handler can send SIGTERM
/// without calling into non-signal-safe Zig runtime code.
pub var proc_pid: std.atomic.Value(std.posix.pid_t) = std.atomic.Value(std.posix.pid_t).init(0);
var gitignore_paths: std.ArrayList(string) = undefined;
pub var watcher_ready = std.atomic.Value(bool).init(false);

pub fn spawnWatcher(task: tasks.Task, skip_gitignore: bool) !void {
    if (task.watcher == null) return error.NoWatcherPresent;
    const watcher = task.watcher.?;

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (skip_gitignore) {
        gitignore_paths = try std.ArrayList(string).initCapacity(allocator, 64);
    } else {
        gitignore_paths = try parseGitignore(allocator, ".gitignore");
        if (config.verbose) {
            for (gitignore_paths.items) |path| {
                zlog.debug("Ignoring {s}", .{path});
            }
        }
    }
    defer gitignore_paths.deinit(allocator);

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    defer argv.deinit(allocator);

    try argv.append(allocator, "fswatch");
    try argv.append(allocator, "-x");
    try argv.appendSlice(allocator, &[_][]const u8{
        "-e", ".*4913$",
        "-e", ".*~$",
        "-e", ".*\\.swp$",
        "-e", ".*", // exclude everything by default
    });

    // Add regex include filters
    for (watcher) |pattern| {
        zlog.info("Watching {s} with regex {s}", .{ ".", pattern });
        try argv.append(allocator, "-i");
        try argv.append(allocator, pattern);
    }

    // Add the directory to watch (after all flags)
    try argv.append(allocator, ".");

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    proc_pid.store(child.id, .seq_cst);

    var stdout = child.stdout.?;
    var buf: [4096]u8 = undefined;
    var reader = stdout.readerStreaming(&buf);

    while (!utils.shouldExit()) {
        // Read one line at a time. takeDelimiter returns null on EOF.
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => break,
            error.StreamTooLong => continue,
        } orelse break; // null = EOF (fswatch exited)

        if (config.verbose) {
            zlog.debug("line: {s}", .{line});
        }

        if (std.mem.indexOf(u8, line, " ")) |idx| {
            const events = line[idx + 1 ..];

            if (std.mem.indexOf(u8, events, "Created") != null or
                std.mem.indexOf(u8, events, "Updated") != null or
                std.mem.indexOf(u8, events, "Removed") != null)
            {
                watcher_ready.store(true, .seq_cst);
            }
        }
    }

    // Clean up: ensure fswatch is terminated
    proc_pid.store(0, .seq_cst);
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

pub fn parseGitignore(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList([]const u8) {
    var patterns = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                return patterns;
            },
            else => {
                return err;
            },
        }
    };
    defer file.close();

    const lines = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    var line_iter = std.mem.splitScalar(u8, lines, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try patterns.append(allocator, trimmed);
    }
    return patterns;
}

pub fn isIgnored(patterns: []const []const u8, raw_path: []const u8) bool {
    var path = raw_path;
    if (std.mem.startsWith(u8, path, "./")) {
        path = path[2..]; // Remove leading './' if present
    }
    for (patterns) |pat| {
        if (std.mem.endsWith(u8, pat, "/")) {
            if (std.mem.startsWith(u8, path, pat)) return true;
        } else if (std.mem.indexOf(u8, path, pat) != null) {
            return true;
        }
    }
    return false;
}
