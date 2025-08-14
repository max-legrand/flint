const std = @import("std");
const config = @import("config");
const zlog = @import("zlog");

const string = []const u8;

const Zon = struct {
    tasks: []Task,
    pub fn deinit(self: *Zon, allocator: std.mem.Allocator) void {
        for (self.tasks) |*task| {
            task.deinit(allocator);
        }
        allocator.free(self.tasks);
    }
};

pub const Flint = struct {
    tasks: []*Task,
    tasks_map: std.StringHashMap(*Task),
    pub fn deinit(self: *Flint, allocator: std.mem.Allocator) void {
        for (self.tasks) |task| {
            task.deinit(allocator);
        }
        allocator.free(self.tasks);

        var iter = self.tasks_map.iterator();
        while (iter.next()) |entry| {
            // We free the value when we iterate over the tasks.
            allocator.free(entry.key_ptr.*);
        }
        self.tasks_map.deinit();
    }
};

pub const Task = struct {
    name: []const u8,
    cmd: []const u8,
    watcher: ?[]string = null,
    deps: ?[]string = null,
    keep_alive: bool = false,
    cwd: ?[]const u8 = null,

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.cmd);
        if (self.cwd) |c| {
            allocator.free(c);
        }
        if (self.watcher) |w| {
            for (w) |s| {
                allocator.free(s);
            }
        }
        if (self.deps) |d| {
            for (d) |s| {
                allocator.free(s);
            }
        }
    }
};

pub fn parseTasks(allocator: std.mem.Allocator) !Flint {
    const cwd = std.fs.cwd();
    const flint_zon = cwd.openFile("flint.zon", .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                @panic("flint.zon not found");
            },
            else => {
                return err;
            },
        }
    };

    const file_data = try flint_zon.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_data);
    const sentinel = try allocator.dupeZ(u8, file_data);
    defer allocator.free(sentinel);

    var data = try std.zon.parse.fromSlice(Zon, allocator, sentinel, null, .{});
    defer data.deinit(allocator);

    if (config.verbose) {
        zlog.debug("Parsed {d} tasks", .{data.tasks.len});
    }

    var flint = Flint{
        .tasks = try allocator.alloc(*Task, data.tasks.len),
        .tasks_map = std.StringHashMap(*Task).init(allocator),
    };

    for (data.tasks, 0..) |task, i| {
        const new_task = try allocator.create(Task);
        const watcher = if (task.watcher) |w| try allocator.alloc(string, w.len) else null;
        if (task.watcher) |w| {
            for (w, 0..) |s, j| {
                watcher.?[j] = try allocator.dupe(u8, s);
            }
        }
        const deps = if (task.deps) |d| try allocator.alloc(string, d.len) else null;
        if (task.deps) |d| {
            for (d, 0..) |s, j| {
                deps.?[j] = try allocator.dupe(u8, s);
            }
        }

        // If the cwd is present, first convert it to an absolute path.
        var cmd_cwd: ?[]const u8 = null;
        if (task.cwd) |dir| {
            if (std.fs.path.isAbsolute(dir)) {
                cmd_cwd = try allocator.dupe(u8, dir);
            } else {
                cmd_cwd = try cwd.realpathAlloc(allocator, dir);
            }
        }

        new_task.* = Task{
            .name = try allocator.dupe(u8, task.name),
            .cmd = try allocator.dupe(u8, task.cmd),
            .watcher = watcher,
            .deps = deps,
            .keep_alive = task.keep_alive,
            .cwd = cmd_cwd,
        };
        flint.tasks[i] = new_task;
        try flint.tasks_map.put(try allocator.dupeZ(u8, task.name), flint.tasks[i]);
    }
    return flint;
}
