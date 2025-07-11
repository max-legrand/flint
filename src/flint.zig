const std = @import("std");
const zlog = @import("zlog");
const utils = @import("utils.zig");
const posix = std.posix;
const builtin = @import("builtin");

pub const Task = struct {
    name: []const u8,
    cmd: ?[]const u8,
    watcher: ?*Watcher,
    deps: [][]const u8,
    deps_tasks: []const *Task,
};

pub const TaskEntry = struct {
    name: []const u8,
    cmd: ?[]const u8 = null,
    watcher: ?[][]const u8 = null,
    deps: ?[][]const u8 = null,
};

pub const Config = struct {
    tasks: []TaskEntry,
};

pub const Flint = struct {
    tasks: std.StringHashMap(*Task),
    file_changed: *std.atomic.Value(bool),

    pub fn deinit(self: *Flint) void {
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            if (value.watcher) |watcher| {
                watcher.deinit();
            }
        }
        self.tasks.deinit();
    }
};

pub fn initWatcher(allocator: std.mem.Allocator, globs: [][]const u8) !*Watcher {
    return try Watcher.init(allocator, globs);
}

pub const Watcher = struct {
    files: std.StringHashMap(i128), // abs path -> mtime
    globs: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, globs: [][]const u8) !*Watcher {
        var watcher = try allocator.create(Watcher);
        watcher.* = Watcher{
            .files = std.StringHashMap(i128).init(allocator),
            .globs = try allocator.dupe([]const u8, globs),
            .allocator = allocator,
        };
        try watcher.rescan();
        return watcher;
    }

    /// Rescan globs and add any new files to the watcher
    pub fn rescan(self: *Watcher) !void {
        for (self.globs) |glob| {
            const expanded = try expandGlob(self.allocator, glob);
            for (expanded) |file| {
                const abs_path = try getAbsolutePath(self.allocator, file);
                if (!self.files.contains(abs_path)) {
                    const path_copy = try self.allocator.dupe(u8, abs_path);
                    const f = std.fs.cwd().openFile(path_copy, .{}) catch continue;
                    defer f.close();
                    const stat = try f.stat();
                    try self.files.put(path_copy, stat.mtime);
                }
            }
        }
    }

    pub fn deinit(self: *Watcher) void {
        var it = self.files.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.files.deinit();
        self.allocator.free(self.globs);
    }
};

fn contains(list: std.ArrayList([]const u8), item: []const u8) bool {
    for (list.items) |i| {
        if (std.mem.eql(u8, i, item)) {
            return true;
        }
    }
    return false;
}

pub fn watchUnilUpdateFswatch(watcher: *Watcher) !void {
    zlog.info("Starting fswatch", .{});
    var dirs = std.ArrayList([]const u8).init(watcher.allocator);
    defer dirs.deinit();

    // Always watch the directories from the globs
    for (watcher.globs) |glob| {
        if (std.mem.lastIndexOf(u8, glob, "/")) |slash| {
            const dir = glob[0..slash];
            if (!contains(dirs, dir)) {
                try dirs.append(dir);
            }
        } else {
            if (!contains(dirs, ".")) {
                try dirs.append(".");
            }
        }
    }

    try watchWithFswatch(watcher.allocator, dirs.items, watcher.globs);
}

pub const WatchProc = struct {
    mutex: std.Thread.Mutex = .{},
    child: ?*std.process.Child = null,
};

pub var FSWatcher = WatchProc{};

pub fn watchWithFswatch(
    allocator: std.mem.Allocator,
    paths: [][]const u8,
    globs: [][]const u8,
) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.append("fswatch");
    try argv.append("-x");
    for (paths) |path| {
        try argv.append(path);
    }

    FSWatcher.mutex.lock();
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    FSWatcher.child = &child;
    FSWatcher.mutex.unlock();

    const fd = child.stdout.?.handle;
    try setNonBlocking(fd);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");

    var buf: [1024]u8 = undefined;
    while (true) {
        if (utils.shouldExit()) {
            _ = child.kill() catch {};
            break;
        }
        // Non-blocking read
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break; // EOF
        const line = buf[0..n];
        if (std.mem.lastIndexOf(u8, line, " ")) |idx| {
            const file_path = line[0..idx];
            const event = line[idx + 1 ..];
            if (std.mem.eql(u8, event, "Created") or std.mem.eql(u8, event, "Updated") or std.mem.eql(u8, event, "Removed")) {
                if (std.mem.startsWith(u8, file_path, cwd) and file_path.len > cwd.len) {
                    const rel_path = file_path[cwd.len + 1 ..];
                    for (globs) |glob| {
                        if (matchGlob(glob, rel_path)) {
                            zlog.info("Matched glob: {s} with file: {s}", .{ glob, rel_path });
                            _ = child.kill() catch {};
                            return;
                        }
                    }
                }
            }
        }
    }
    _ = child.kill() catch {};
}

fn matchGlob(glob: []const u8, path: []const u8) bool {
    var gi: usize = 0;
    var pi: usize = 0;
    while (gi < glob.len and pi < path.len) {
        switch (glob[gi]) {
            '*' => {
                // Collapse multiple '*' in a row
                while (gi + 1 < glob.len and glob[gi + 1] == '*') gi += 1;
                if (gi + 1 == glob.len) return true; // trailing * matches everything
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
    // Skip trailing '*' in glob
    while (gi < glob.len and glob[gi] == '*') gi += 1;
    return gi == glob.len and pi == path.len;
}

pub fn watchUntilUpdate(watcher: *Watcher) !void {
    zlog.info("Starting polling watcher", .{});
    const rescan_interval_ms: i128 = 2000;
    const idle_sleep = 200 * std.time.ns_per_ms;
    const active_sleep = 50 * std.time.ns_per_ms;
    var last_rescan: i128 = std.time.milliTimestamp();
    var last_change_time: i128 = std.time.milliTimestamp();
    const delta_threshold_ms = 1000;

    while (!utils.shouldExit()) {
        const now = std.time.milliTimestamp();
        const delta = now - last_change_time;

        // Rescan globs for new files every rescan_interval_ms
        if (now - last_rescan > rescan_interval_ms) {
            watcher.rescan() catch |err| {
                zlog.err("Watcher rescan failed: {}", .{err});
            };
            last_rescan = now;
        }

        var keys = watcher.files.keyIterator();
        var any_dirty = false;

        while (keys.next()) |key| {
            const name = key.*;
            const file = std.fs.cwd().openFile(name, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;

            const old = watcher.files.get(name).?;
            if (stat.mtime > old) {
                watcher.files.put(name, stat.mtime) catch continue;
                any_dirty = true;
                zlog.info("Triggering task - {s} changed", .{name});
                return; // short-circuit
            }
        }

        if (any_dirty) {
            last_change_time = std.time.nanoTimestamp();
            return;
        }

        var sleep_duration: u64 = active_sleep;
        if (delta > delta_threshold_ms) {
            sleep_duration = idle_sleep;
        }
        std.Thread.sleep(sleep_duration);
    }
    return error.WatcherExited;
}

fn getAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.realpathAlloc(allocator, path);
}

/// Only supports:
///   - "dir/*" (all files in dir)
///   - "dir/*.ext" (all files in dir with extension)
///   - "dir/**/*.ext" (all files recursively in dir with extension)
///   - "file" (literal file)
fn expandGlob(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) ![][]const u8 {
    // Handle recursive globs like "dir/**/*.ext"
    if (std.mem.containsAtLeast(u8, pattern, 1, "**/")) {
        if (std.mem.indexOf(u8, pattern, "**/")) |idx| {
            const dir = if (idx == 0) "." else pattern[0..idx];
            const subpattern = pattern[idx + 3 ..];
            return try findFilesRecursive(allocator, dir, subpattern);
        }
    }

    // Find last '/' to split dir and pattern
    if (std.mem.lastIndexOf(u8, pattern, "/")) |slash| {
        const dir = pattern[0..slash];
        const subpattern = pattern[slash + 1 ..];
        if (std.mem.eql(u8, subpattern, "*")) {
            return try findFilesInDir(allocator, dir, "*");
        } else if (std.mem.startsWith(u8, subpattern, "*.")) {
            return try findFilesInDir(allocator, dir, subpattern);
        } else {
            // No glob in subpattern, treat as literal file
            var list = try allocator.alloc([]const u8, 1);
            list[0] = pattern;
            return list;
        }
    }

    // Fallback: treat as literal file
    var list = try allocator.alloc([]const u8, 1);
    list[0] = pattern;
    return list;
}

fn findFilesInDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var files = std.ArrayList([]const u8).init(allocator);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            if (std.mem.eql(u8, pattern, "*") or
                (std.mem.startsWith(u8, pattern, "*.") and std.mem.endsWith(u8, entry.name, pattern[1..])))
            {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try files.append(full_path);
            }
        }
    }
    return files.toOwnedSlice();
}

fn findFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        if (entry.kind == .file) {
            if (std.mem.eql(u8, pattern, "*") or
                (std.mem.startsWith(u8, pattern, "*.") and std.mem.endsWith(u8, entry.name, pattern[1..])))
            {
                try files.append(full_path);
            }
        } else if (entry.kind == .directory and
            !std.mem.eql(u8, entry.name, ".") and
            !std.mem.eql(u8, entry.name, ".."))
        {
            const subfiles = try findFilesRecursive(allocator, full_path, pattern);
            for (subfiles) |f| try files.append(f);
        }
    }
    return files.toOwnedSlice();
}

fn valueToString(val: std.json.Value) []const u8 {
    return val.string;
}

// Helper function for DFS
fn visit(
    allocator: std.mem.Allocator,
    task: *Task,
    tasks: *const std.StringHashMap(*Task),
    visited: *std.StringHashMap(bool),
    sorted: *std.ArrayList(*Task),
    stack: *std.StringHashMap(bool),
) !void {
    if (visited.get(task.name)) |_| {
        return;
    }
    if (stack.get(task.name)) |_| {
        return error.CycleDetected;
    }
    try stack.put(task.name, true);

    for (task.deps) |dep_name| {
        const dep_task = tasks.get(dep_name) orelse
            return error.DependencyNotFound;
        try visit(allocator, dep_task, tasks, visited, sorted, stack);
    }
    _ = stack.remove(task.name);
    try visited.put(task.name, true);
    try sorted.append(task);
}

pub fn topologicalSort(
    allocator: std.mem.Allocator,
    start: *Task,
    tasks: std.StringHashMap(*Task),
) ![]const *Task {
    var sorted = std.ArrayList(*Task).init(allocator);
    var visited = std.StringHashMap(bool).init(allocator);
    var stack = std.StringHashMap(bool).init(allocator); // for cycle detection
    defer visited.deinit();
    defer stack.deinit();

    try visit(allocator, start, &tasks, &visited, &sorted, &stack);

    return sorted.toOwnedSlice();
}

pub fn parseTasks(
    allocator: std.mem.Allocator,
    filepath: []const u8,
) !Flint {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    const zon_data = try allocator.dupeZ(u8, data);

    const config = try std.zon.parse.fromSlice(Config, allocator, zon_data, null, .{});

    var tasks_map = std.StringHashMap(*Task).init(allocator);
    for (config.tasks) |entry| {
        const task = try allocator.create(Task);
        task.* = Task{
            .name = entry.name,
            .cmd = entry.cmd,
            .deps = entry.deps orelse &[_][]const u8{},
            .watcher = if (entry.watcher) |watcher| try initWatcher(allocator, watcher) else null,
            .deps_tasks = &[_]*Task{},
        };
        try tasks_map.put(entry.name, task);
    }

    var iter = tasks_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        zlog.debug("Mapping deps for task '{s}'", .{key});
        var value = entry.value_ptr.*;
        if (value.deps.len > 0) {
            value.deps_tasks = try topologicalSort(allocator, value, tasks_map);
            try tasks_map.put(key, value);
        } else if (value.cmd == null) {
            return error.TaskHasNoCommandOrDeps;
        }
    }

    const file_changed = try allocator.create(std.atomic.Value(bool));
    file_changed.* = std.atomic.Value(bool).init(false);

    const flint = Flint{
        .tasks = tasks_map,
        .file_changed = file_changed,
    };

    return flint;
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const O_NONBLOCK = 0o0004000;
    switch (builtin.os.tag) {
        .linux => {
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
        },
        .macos => {
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
        },
        else => {
            @panic("Unsupported OS");
        },
    }
}
