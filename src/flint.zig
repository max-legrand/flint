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

    pub fn initWatcher(self: *Flint, allocator: std.mem.Allocator, files: [][]const u8) !*Watcher {
        const watcher = try Watcher.init(allocator, files);

        const thread = try std.Thread.spawn(
            .{ .allocator = allocator },
            watcherThread,
            .{ watcher, self.file_changed },
        );
        try self.threads.append(thread);

        return watcher;
    }
};

pub fn watcherThread(
    watcher: *Watcher,
    file_changed: *std.atomic.Value(bool),
) void {
    if (builtin.os.tag == .linux) {
        zlog.info("Starting watcher thread", .{});
        var buf: [4096]u8 = undefined;
        const mask = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MOVE_SELF | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.ATTRIB;
        var pending_readd: ?[]const u8 = null;

        while (!utils.shouldExit()) {
            const n = std.os.linux.read(watcher.fd, &buf, buf.len);
            if (n == -1) {
                if (std.os.errno(-1) == std.os.EAGAIN) {
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                } else {
                    break;
                }
            }
            var i: usize = 0;
            const max_event_size = @sizeOf(std.os.linux.inotify_event) + 4096;
            while (i + @sizeOf(std.os.linux.inotify_event) <= n) {
                const event_ptr = &buf[i];
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(event_ptr));
                const event_size = @sizeOf(std.os.linux.inotify_event) + event.len;
                if (event_size > max_event_size) break;
                if (i + event_size > n) break;

                var file_name: ?[]const u8 = null;
                var it = watcher.wd_map.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == event.wd) {
                        file_name = entry.key_ptr.*;
                        break;
                    }
                }

                if ((event.mask & std.os.linux.IN.CLOSE_WRITE) != 0) {
                    if (!file_changed.load(.seq_cst)) {
                        file_changed.store(true, .seq_cst);
                    }
                } else if ((event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF)) != 0) {
                    if (file_name) |fname| {
                        pending_readd = fname;
                    }
                }

                i += event_size;
            }

            // Handle pending re-add after processing all events
            if (pending_readd) |fname| {
                std.Thread.sleep(500 * std.time.ns_per_ms);
                if (!file_changed.load(.seq_cst)) {
                    file_changed.store(true, .seq_cst);
                }
                var exists = true;
                std.fs.cwd().access(fname, .{}) catch {
                    exists = false;
                };

                if (exists) {
                    _ = watcher.wd_map.remove(fname);
                    const wd_raw = std.os.linux.inotify_add_watch(
                        watcher.fd,
                        std.heap.page_allocator.dupeZ(u8, fname) catch @panic("Unable to allocate memory"),
                        mask,
                    );
                    const wd_lg: i64 = @bitCast(wd_raw);
                    const wd: i32 = @intCast(wd_lg);
                    if (wd >= 0) {
                        watcher.wd_map.put(fname, wd) catch {};
                        pending_readd = null;
                    } else {
                        zlog.err("Failed to re-add inotify watch for {s}, will retry", .{fname});
                    }
                }
            }
        }
    } else if (builtin.os.tag == .macos) {
        zlog.info("Starting kqueue watcher thread", .{});
        var events: [16]std.posix.Kevent = undefined;
        while (!utils.shouldExit()) {
            const n = std.posix.kevent(
                watcher.kq,
                &[_]std.posix.Kevent{},
                events[0..],
                null,
            ) catch |err| {
                zlog.err("kqueue error: {s}", .{@errorName(err)});
                break;
            };
            if (n == 0) {
                std.Thread.sleep(100_000);
                continue;
            }
            for (events[0..n]) |event| {
                if ((event.flags & (std.posix.system.NOTE.WRITE | std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME | std.posix.system.NOTE.EXTEND | std.posix.system.NOTE.ATTRIB | std.posix.system.NOTE.RENAME)) != 0) {
                    if (!file_changed.load(.seq_cst)) {
                        file_changed.store(true, .seq_cst);
                    }
                }
            }
        }
    } else {
        // Polling fallback
        while (true) {
            var keys = watcher.files.keyIterator();
            while (keys.next()) |key| {
                const file = std.fs.cwd().openFile(key.*, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                if (stat.mtime > watcher.files.get(key.*).?) {
                    watcher.files.put(key.*, stat.mtime) catch continue;
                    if (!file_changed.load(.seq_cst)) {
                        file_changed.store(true, .seq_cst);
                    }
                }
            }
            std.time.sleep(100 * std.time.ns_per_ms);
        }
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

pub const Watcher = if (builtin.os.tag == .linux)
    LinuxWatcher
else if (builtin.os.tag == .macos)
    MacOSWatcher
else
    PollingWatcher;

const MacOSWatcher = struct {
    kq: std.posix.fd_t,
    files: std.StringHashMap(i128),
    fds: std.StringHashMap(std.posix.fd_t),

    pub fn init(allocator: std.mem.Allocator, files: [][]const u8) !*MacOSWatcher {
        var watcher = try allocator.create(MacOSWatcher);
        watcher.* = MacOSWatcher{
            .kq = try std.posix.kqueue(),
            .files = std.StringHashMap(i128).init(allocator),
            .fds = std.StringHashMap(std.posix.fd_t).init(allocator),
        };

        for (files) |glob| {
            const expanded = try expandGlob(allocator, glob);
            for (expanded) |file| {
                const f = std.fs.cwd().openFile(file, .{}) catch continue;
                const stat = try f.stat();
                try watcher.files.put(file, stat.mtime);
                try watcher.fds.put(file, f.handle);

                const kev = std.posix.Kevent{
                    .ident = @intCast(f.handle),
                    .filter = std.posix.system.EVFILT.VNODE,
                    .flags = std.posix.system.EV.ENABLE | std.posix.system.EV.ADD | std.posix.system.EV.CLEAR,
                    .fflags = std.posix.system.NOTE.WRITE | std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME | std.posix.system.NOTE.EXTEND | std.posix.system.NOTE.ATTRIB,
                    .data = 0,
                    .udata = 0,
                };

                _ = try std.posix.kevent(
                    watcher.kq,
                    &[_]std.posix.Kevent{kev},
                    &[_]std.posix.Kevent{},
                    null,
                );
                // Don't close f, keep it open for kqueue
            }
            return watcher;
        }
    }

    pub fn deinit(self: *MacOSWatcher) void {
        var it = self.fds.valueIterator();
        while (it.next()) |fd| {
            _ = std.posix.close(fd);
        }
        self.fds.deinit();
        self.files.deinit();
        _ = std.posix.close(self.kq);
    }
};

const LinuxWatcher = struct {
    fd: std.os.linux.fd_t,
    wd_map: std.StringHashMap(i32),

    pub fn init(allocator: std.mem.Allocator, files: [][]const u8) !*LinuxWatcher {
        var watcher = try allocator.create(LinuxWatcher);
        watcher.* = LinuxWatcher{
            .fd = @intCast(std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK)),
            .wd_map = std.StringHashMap(i32).init(allocator),
        };

        for (files) |f| {
            const expanded = try expandGlob(allocator, f);
            for (expanded) |file| {
                const mask = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MOVE_SELF | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.ATTRIB;
                const wd_raw = std.os.linux.inotify_add_watch(
                    watcher.fd,
                    try allocator.dupeZ(u8, file),
                    mask,
                );
                const wd_lg: i64 = @bitCast(wd_raw);
                const wd: i32 = @intCast(wd_lg);
                if (wd < 0) return error.InotifyAddWatchFailed;
                try watcher.wd_map.put(file, wd);
            }
        }
        return watcher;
    }

    pub fn deinit(self: *LinuxWatcher) void {
        var it = self.wd_map.valueIterator();
        while (it.next()) |wd| {
            _ = std.os.linux.inotify_rm_watch(self.fd, @intCast(wd.*));
        }
        self.wd_map.deinit();
        _ = std.os.linux.close(self.fd);
    }
};

const PollingWatcher = struct {
    files: std.StringHashMap(i128),

    pub fn init(allocator: std.mem.Allocator, files: [][]const u8) !*PollingWatcher {
        var watcher = try allocator.create(PollingWatcher);
        watcher.* = PollingWatcher{
            .files = std.StringHashMap(i128).init(allocator),
        };

        for (files) |file| {
            const f = std.fs.cwd().openFile(file, .{}) catch continue;
            defer f.close();
            const stat = try f.stat();
            try watcher.files.put(file, stat.mtime);
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
    // Only supports "*.zig" and "**/*.zig" for now
    if (std.mem.startsWith(u8, pattern, "**/")) {
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
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, pattern[1..])) {
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try files.append(full_path);
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

pub fn checkUpdate(watcher: *Watcher, file_changed: *std.atomic.Value(bool)) void {
    while (!utils.shouldExit()) {
        var keys = watcher.files.keyIterator();
        while (keys.next()) |key| {
            const file = std.fs.cwd().openFile(key.*, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        continue;
                    },
                    else => {
                        break;
                    },
                }
            };
            defer file.close();

            const stat = file.stat() catch @panic("Cannot get file stat");
            if (stat.mtime > watcher.files.get(key.*).?) {
                watcher.files.put(key.*, stat.mtime) catch @panic("Failed to update file");
                if (!file_changed.load(.seq_cst)) {
                    file_changed.store(true, .seq_cst);
                }
            }
        }
        std.Thread.sleep(100_000);
    }
}
