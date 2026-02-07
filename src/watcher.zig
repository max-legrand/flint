const std = @import("std");
const config = @import("config");
const zlog = @import("zlog");
const tasks = @import("tasks.zig");
const utils = @import("utils.zig");

const string = []const u8;

pub var proc: ?*std.process.Child = null;
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

    // Add regex filters for each glob
    for (watcher) |glob| {
        zlog.info("Watching {s} with regex {s}", .{ ".", glob });
        try argv.append(allocator, "-i");
        try argv.append(allocator, glob);
        try argv.append(allocator, ".");
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    proc = &child;
    try child.spawn();

    var stdout = child.stdout.?;
    var buf: [1024]u8 = undefined;
    var reader = stdout.readerStreaming(&buf);

    while (true) {
        if (utils.shouldExit()) {
            break;
        }
        const lines = try reader.interface.allocRemaining(allocator, .unlimited);
        var lines_iter = std.mem.splitScalar(u8, lines, '\n');
        while (lines_iter.next()) |line| {
            if (std.mem.indexOf(u8, line, " ")) |idx| {
                const events = line[idx + 1 ..];
                var event_set = std.StringHashMap(void).init(allocator);
                defer event_set.deinit();

                var event_iter = std.mem.splitScalar(u8, events, ' ');
                while (event_iter.next()) |event| {
                    try event_set.put(event, {});
                }

                if (config.verbose) {
                    zlog.debug("line: {s}", .{line});
                }

                if (event_set.contains("Created") or event_set.contains("Updated") or event_set.contains("Removed")) {
                    // No need to re-filter: fswatch already applied regex
                    watcher_ready.store(true, .seq_cst);
                }
            }
        }
    }
}

// Extract the base directory from a glob pattern
fn globBaseDir(glob: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, glob, "*?")) |idx| {
        return std.fs.path.dirname(glob[0..idx]) orelse ".";
    }
    return std.fs.path.dirname(glob) orelse ".";
}

// Convert a glob pattern into a regex string for fswatch
fn globToRegex(glob: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).empty;

    try buf.append(allocator, '^');
    var i: usize = 0;
    while (i < glob.len) : (i += 1) {
        switch (glob[i]) {
            '*' => {
                if (i + 1 < glob.len and glob[i + 1] == '*') {
                    // ** → .*
                    try buf.appendSlice(allocator, ".*");
                    i += 1; // skip second *
                } else {
                    // * → [^/]* (match within a single directory)
                    try buf.appendSlice(allocator, "[^/]*");
                }
            },
            '?' => try buf.append(allocator, '.'),
            '.' => try buf.appendSlice(allocator, "\\."),
            '/' => try buf.append(allocator, '/'),
            else => try buf.append(allocator, glob[i]),
        }
    }
    try buf.append(allocator, '$');

    return buf.toOwnedSlice(allocator);
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
