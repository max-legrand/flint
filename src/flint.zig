const std = @import("std");
const zlog = @import("zlog");
const builtin = @import("builtin");
const utils = @import("utils.zig");

pub const Task = struct {
    name: []const u8,
    cmd: ?[]const u8,
    watcher: ?*Watcher,
    deps: [][]const u8,
    deps_tasks: []const *Task,
};

pub const Tasks = struct {
    tasks: std.StringHashMap(Task),

    pub fn deinit(self: *Tasks) void {
        for (self.tasks.values()) |task| {
            if (task.watcher) |watcher| {
                watcher.deinit();
            }
        }
        self.tasks.deinit();
    }
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
    threads: std.ArrayList(std.Thread),
    file_changed: *std.atomic.Value(bool),

    pub fn deinit(self: *Flint) void {
        for (self.threads.items) |thread| {
            thread.join();
        }
        self.tasks.deinit();
    }

    pub fn startWatcherThread(self: *Flint, task: *Task, allocator: std.mem.Allocator) !void {
        const thread = try std.Thread.spawn(
            .{ .allocator = allocator },
            watcherThread,
            .{ task.watcher.?, self.file_changed },
        );
        try self.threads.append(thread);
    }
};

pub fn initWatcher(allocator: std.mem.Allocator, files: [][]const u8) !*Watcher {
    const watcher = try Watcher.init(allocator, files);

    return watcher;
}

pub fn watcherThread(
    watcher: *Watcher,
    file_changed: *std.atomic.Value(bool),
) void {
    zlog.info("Starting polling watcher thread", .{});

    const idle_sleep = 200 * std.time.ns_per_ms;
    const active_sleep = 50 * std.time.ns_per_ms;
    var last_change_time: i128 = std.time.milliTimestamp();
    const delta_threshold_ms = 1000;

    while (!utils.shouldExit()) {
        for (watcher.globs) |glob| {
            const expanded = expandGlob(watcher.allocator, glob) catch continue;
            defer watcher.allocator.free(expanded);
            for (expanded) |file| {
                if (!watcher.files.contains(file)) {
                    // New file detected!
                    const f = std.fs.cwd().openFile(file, .{}) catch continue;
                    defer f.close();
                    const stat = f.stat() catch continue;
                    const file_copy = watcher.allocator.dupe(u8, file) catch continue;
                    watcher.files.put(file_copy, stat.mtime) catch continue;
                    zlog.info("New file detected: {s}", .{file});
                    file_changed.store(true, .seq_cst);
                }
            }
        }
        const now = std.time.milliTimestamp();
        const delta = now - last_change_time;

        var keys = watcher.files.keyIterator();
        var any_dirty = false;

        while (keys.next()) |key| {
            const file = std.fs.cwd().openFile(key.*, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;

            const old = watcher.files.get(key.*).?;
            if (stat.mtime > old) {
                watcher.files.put(key.*, stat.mtime) catch continue;
                any_dirty = true;
                zlog.info("Triggering task - {s} changed", .{key.*});
                break; // short-circuit
            }
        }

        if (any_dirty) {
            last_change_time = std.time.nanoTimestamp();
            if (!file_changed.load(.seq_cst)) {
                file_changed.store(true, .seq_cst);
            }
        }

        var sleep_duration: u64 = active_sleep;
        if (delta > delta_threshold_ms) {
            sleep_duration = idle_sleep;
        }
        std.Thread.sleep(sleep_duration);
    }
}

pub fn map(
    allocator: std.mem.Allocator,
    comptime In: type,
    comptime Out: type,
    input: []const In,
    comptime func: fn (In) Out,
) ![]Out {
    var result = try allocator.alloc(Out, input.len);
    for (input, 0..) |item, i| {
        result[i] = func(item);
    }
    return result;
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
    defer allocator.free(data);

    const zon_data = try allocator.dupeZ(u8, data);
    defer allocator.free(zon_data);

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
        .threads = std.ArrayList(std.Thread).init(allocator),
        .file_changed = file_changed,
    };

    return flint;
}

pub const Watcher =
    PollingWatcher;

const PollingWatcher = struct {
    files: std.StringHashMap(i128),
    globs: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, files: [][]const u8) !*PollingWatcher {
        var watcher = try allocator.create(PollingWatcher);
        watcher.* = PollingWatcher{
            .files = std.StringHashMap(i128).init(allocator),
            .globs = try allocator.dupe([]const u8, files),
            .allocator = allocator,
        };

        for (files) |glob| {
            const expanded = try expandGlob(allocator, glob);
            for (expanded) |file| {
                const f = std.fs.cwd().openFile(file, .{}) catch continue;
                defer f.close();
                const stat = try f.stat();
                try watcher.files.put(file, stat.mtime);
            }
        }
        return watcher;
    }

    pub fn deinit(self: *PollingWatcher) void {
        self.files.deinit();
    }
};

fn expandGlob(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) ![][]const u8 {
    if (std.mem.eql(u8, pattern, "*")) {
        // Match all files in current directory
        return try findFilesInDir(allocator, ".", "*");
    } else if (std.mem.eql(u8, pattern, "./*")) {
        // Match all files in current directory
        return try findFilesInDir(allocator, ".", "*");
    } else if (std.mem.startsWith(u8, pattern, "**/")) {
        // Recursive search
        const subpattern = pattern[3..];
        return try findFilesRecursive(allocator, ".", subpattern);
    } else if (std.mem.startsWith(u8, pattern, "*.")) {
        // Non-recursive search in cwd
        return try findFilesInDir(allocator, ".", pattern);
    } else if (std.mem.indexOf(u8, pattern, "*")) |star| {
        // e.g. "src/*.zig"
        const dir = pattern[0 .. star - 1];
        const subpattern = pattern[star..];
        return try findFilesInDir(allocator, dir, subpattern);
    } else {
        // Not a glob, just return the file itself
        var list = try allocator.alloc([]const u8, 1);
        list[0] = pattern;
        return list;
    }
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
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, pattern[1..])) {
            try files.append(full_path);
        } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
            const subfiles = try findFilesRecursive(allocator, full_path, pattern);
            for (subfiles) |f| try files.append(f);
        }
    }
    return files.toOwnedSlice();
}
