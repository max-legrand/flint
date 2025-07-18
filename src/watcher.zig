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

        if (std.mem.lastIndexOf(u8, line.?, " ")) |idx| {
            const file_path = line.?[0..idx];
            const event = line.?[idx + 1 ..];

            if (config.verbose) {
                zlog.debug("file: {s}, event: {s}", .{ file_path, event });
            }

            if (std.mem.eql(u8, event, "Created") or std.mem.eql(u8, event, "Updated") or std.mem.eql(u8, event, "Removed")) {
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

// Your matchGlob function as before
fn matchGlob(glob: []const u8, path: []const u8) bool {
    var gi: usize = 0;
    var pi: usize = 0;
    while (gi < glob.len and pi < path.len) {
        switch (glob[gi]) {
            '*' => {
                while (gi + 1 < glob.len and glob[gi + 1] == '*') gi += 1;
                if (gi + 1 == glob.len) return true;
                gi += 1;
                while (pi < path.len) {
                    if (matchGlob(glob[gi..], path[pi..])) return true;
                    pi += 1;
                }
                return false;
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
    while (gi < glob.len and glob[gi] == '*') gi += 1;
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
