const std = @import("std");
const zlog = @import("zlog");
const builtin = @import("builtin");
const utils = @import("utils.zig");

pub const Task = struct {
    cmd: []const u8,
};

pub const Tasks = struct {
    tasks: std.StringHashMap(Task),

    pub fn deinit(self: *Tasks) void {
        self.tasks.deinit();
    }
};

pub const TaskEntry = struct {
    name: []const u8,
    cmd: []const u8,
};

pub const Config = struct {
    tasks: []TaskEntry,
    watcher: [][]const u8,
};

pub const Flint = struct {
    tasks: std.StringHashMap(Task),
    watcher: ?*Watcher,
    threads: std.ArrayList(std.Thread),
    file_changed: *std.atomic.Value(bool),

    pub fn deinit(self: *Flint) void {
        zlog.info("Deinitializing flint", .{});
        self.tasks.deinit();
        zlog.info("Joining threads", .{});
        for (self.threads.items) |thread| {
            thread.join();
        }
        zlog.info("Deinitializing watcher", .{});

        if (self.watcher) |watcher| {
            watcher.deinit();
        }
    }

    pub fn initWatcher(_: *Flint, allocator: std.mem.Allocator, files: [][]const u8) !*Watcher {
        const watcher = try Watcher.init(allocator, files);

        return watcher;
    }

    pub fn startWatcherThread(self: *Flint, allocator: std.mem.Allocator) !void {
        const thread = try std.Thread.spawn(
            .{ .allocator = allocator },
            watcherThread,
            .{ self.watcher.?, self.file_changed },
        );
        try self.threads.append(thread);
    }
};

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

pub fn parseTasks(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    command: []const u8,
) !Flint {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const zon_data = try allocator.dupeZ(u8, data);
    defer allocator.free(zon_data);

    const config = try std.zon.parse.fromSlice(Config, allocator, zon_data, null, .{});
    if (std.mem.eql(u8, command, "watch") and config.watcher.len == 0) {
        zlog.err("No watchers defined in config with `watch` command used", .{});
        return error.NoWatchers;
    }

    var tasks_map = std.StringHashMap(Task).init(allocator);
    for (config.tasks) |entry| {
        try tasks_map.put(entry.name, Task{ .cmd = entry.cmd });
    }

    const file_changed = try allocator.create(std.atomic.Value(bool));
    file_changed.* = std.atomic.Value(bool).init(false);

    var flint = Flint{
        .tasks = tasks_map,
        .watcher = null,
        .threads = std.ArrayList(std.Thread).init(allocator),
        .file_changed = file_changed,
    };
    if (std.mem.eql(u8, command, "watch")) {
        flint.watcher = try flint.initWatcher(allocator, config.watcher);
    }

    return flint;
}

pub const Watcher =
    PollingWatcher;

const PollingWatcher = struct {
    files: std.StringHashMap(i128),

    pub fn init(allocator: std.mem.Allocator, files: [][]const u8) !*PollingWatcher {
        var watcher = try allocator.create(PollingWatcher);
        watcher.* = PollingWatcher{
            .files = std.StringHashMap(i128).init(allocator),
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
