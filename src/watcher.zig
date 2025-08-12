const std = @import("std");
const config = @import("config");
const zlog = @import("zlog");
const tasks = @import("tasks.zig");
const utils = @import("utils.zig");

const string = []const u8;

pub var proc: ?*std.process.Child = null;
var gitignore_paths: std.ArrayList(string) = undefined;
pub var watcher_ready = std.atomic.Value(bool).init(false);

const Set = std.StringHashMap(struct {});

pub fn spawnWatcher(task: tasks.Task, skip_gitignore: bool) !void {
    if (task.watcher == null) return error.NoWatcherPresent;
    const watcher = task.watcher.?;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (skip_gitignore) {
        gitignore_paths = std.ArrayList(string).init(allocator);
    } else {
        gitignore_paths = try parseGitignore(allocator, ".gitignore");
        if (config.verbose) {
            for (gitignore_paths.items) |path| {
                zlog.debug("Ignoring {s}", .{path});
            }
        }
    }
    defer gitignore_paths.deinit();

    var dirs = Set.init(allocator);
    defer dirs.deinit();

    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    for (watcher) |s| {
        if (std.mem.indexOfAny(u8, s, "*?") != null) {
            // Recursively walk and match
            const dir_part = std.fs.path.dirname(s) orelse ".";
            if (!isIgnored(gitignore_paths.items, dir_part)) {
                try dirs.put(dir_part, .{});
            }
            try walkAndMatch(allocator, ".", s, &dirs);
        } else {
            const stat = cwd.statFile(s) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };

            if (stat.kind == .directory and !isIgnored(gitignore_paths.items, s)) {
                try dirs.put(s, .{});
            } else {
                if (!isIgnored(gitignore_paths.items, s)) {
                    const parent = std.fs.path.dirname(s) orelse ".";
                    try dirs.put(parent, .{});
                }
            }
        }
    }

    zlog.debug("Watching {d} directories", .{dirs.count()});

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("fswatch");
    try argv.append("-x");
    var iter = dirs.keyIterator();
    while (iter.next()) |dir| {
        if (config.verbose) {
            zlog.debug("  - {s}", .{dir.*});
        }
        try argv.append(dir.*);
    }
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    proc = &child;
    try child.spawn();

    var reader = child.stdout.?.reader();
    var buf: [1024]u8 = undefined;

    while (true) {
        if (utils.shouldExit()) {
            break;
        }
        const line = reader.readUntilDelimiterOrEof(&buf, '\n') catch {
            break;
        };
        if (line == null) break;

        if (std.mem.indexOf(u8, line.?, " ")) |idx| {
            const file_path = line.?[0..idx];
            const events = line.?[idx + 1 ..];
            var event_set = std.StringHashMap(void).init(allocator);
            defer event_set.deinit();

            var event_iter = std.mem.splitScalar(u8, events, ' ');
            while (event_iter.next()) |event| {
                try event_set.put(event, {});
            }

            if (config.verbose) {
                zlog.debug("line: {s}", .{line.?});
            }

            if (event_set.contains("Created") or event_set.contains("Updated") or event_set.contains("Removed")) {
                if (std.mem.startsWith(u8, file_path, cwd_path) and file_path.len > cwd_path.len) {
                    // +1 to skip the trailing slash
                    const rel_path = file_path[cwd_path.len + 1 ..];
                    for (task.watcher.?) |glob| {
                        if (config.verbose) {
                            zlog.debug("Matching {s} with {s}", .{ glob, rel_path });
                        }
                        if (matchGlob(glob, rel_path)) {
                            zlog.debug("Matched glob {s} against {s}", .{ glob, rel_path });
                            watcher_ready.store(true, .seq_cst);
                            break;
                        }
                    }
                }
            }
        }
    }
}

// Recursively walk the directory tree and match files against the glob
fn walkAndMatch(
    allocator: std.mem.Allocator,
    base: string,
    glob: string,
    dirs: *Set,
) !void {
    var dir = try std.fs.cwd().openDir(base, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel_path = try std.fs.path.join(
            allocator,
            &.{ base, entry.name },
        );
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.name, ".") and
                !std.mem.eql(u8, entry.name, ".."))
            {
                // Recurse into subdirectory
                try walkAndMatch(allocator, rel_path, glob, dirs);
            }
        } else {
            // Match the relative path against the glob
            if (matchGlob(glob, rel_path) and !isIgnored(gitignore_paths.items, rel_path)) {
                const parent = std.fs.path.dirname(rel_path) orelse ".";
                try dirs.put(try allocator.dupe(u8, parent), .{});
            }
        }
    }
}

// Enhanced matchGlob function with ** support for recursive directory matching
fn matchGlob(glob: []const u8, path: []const u8) bool {
    var gi: usize = 0;
    var pi: usize = 0;
    while (gi < glob.len and pi < path.len) {
        switch (glob[gi]) {
            '*' => {
                // Check if this is a ** pattern
                if (gi + 1 < glob.len and glob[gi + 1] == '*') {
                    // Handle ** pattern - matches zero or more directories
                    gi += 2; // Skip both *

                    // Skip any trailing slashes after **
                    while (gi < glob.len and glob[gi] == '/') gi += 1;

                    // If ** is at the end of the glob, it matches everything
                    if (gi == glob.len) return true;

                    // Try matching the rest of the pattern at every position in the path
                    while (pi <= path.len) {
                        if (matchGlob(glob[gi..], path[pi..])) return true;

                        // Move to next character, or next directory boundary
                        if (pi < path.len) {
                            pi += 1;
                        } else {
                            break;
                        }
                    }
                    return false;
                } else {
                    // Single * - matches any sequence except directory separators
                    if (gi + 1 == glob.len) {
                        // * at end matches rest of current path segment
                        while (pi < path.len and path[pi] != '/') pi += 1;
                        return pi == path.len;
                    }
                    gi += 1;
                    while (pi < path.len and path[pi] != '/') {
                        if (matchGlob(glob[gi..], path[pi..])) return true;
                        pi += 1;
                    }
                    return false;
                }
            },
            '?' => {
                if (path[pi] == '/') return false;
                gi += 1;
                pi += 1;
            },
            else => {
                if (glob[gi] != path[pi]) return false;
                gi += 1;
                pi += 1;
            },
        }
    }

    // Handle trailing * or ** in glob
    while (gi < glob.len) {
        if (glob[gi] == '*') {
            if (gi + 1 < glob.len and glob[gi + 1] == '*') {
                // Trailing ** matches everything
                return true;
            } else {
                // Trailing * matches if we're at end of path or at a directory boundary
                gi += 1;
            }
        } else {
            break;
        }
    }

    return gi == glob.len and pi == path.len;
}

pub fn parseGitignore(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList([]const u8) {
    var patterns = std.ArrayList([]const u8).init(allocator);
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

    var reader = file.reader();
    while (true) {
        const line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);
        if (line == null) break;
        const trimmed = std.mem.trim(u8, line.?, " \r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try patterns.append(trimmed);
    }
    return patterns;
}

pub fn isIgnored(patterns: []const []const u8, raw_path: []const u8) bool {
    var path = raw_path;
    if (std.mem.startsWith(u8, path, "./")) {
        path = path[2..]; // Remove leading './' if present
    }
    for (patterns) |pat| {
        // Very basic - just check for prefix match or glob match
        if (std.mem.endsWith(u8, pat, "/")) {
            if (std.mem.startsWith(u8, path, pat)) return true;
        } else if (std.mem.indexOf(u8, path, pat) != null) {
            return true;
        }
    }
    return false;
}
