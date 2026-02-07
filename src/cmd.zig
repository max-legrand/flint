const std = @import("std");
const zlog = @import("zlog");
const string = []const u8;

// Spawn a child process and return a handle to it.
pub fn executeCommandAsync(allocator: std.mem.Allocator, args: []string, cwd: ?string, env: ?[]string) !std.process.Child {
    var child = std.process.Child.init(args, allocator);
    if (cwd) |dir| {
        child.cwd = dir;
    }

    if (env) |e| {
        var env_map = try allocator.create(std.process.EnvMap);
        env_map.* = try std.process.getEnvMap(allocator);
        for (e) |s| {
            const eq_idx = std.mem.indexOfScalar(u8, s, '=') orelse {
                zlog.warn("Skipping invalid env entry (no '='): {s}", .{s});
                continue;
            };
            if (eq_idx == 0 or eq_idx == s.len - 1) {
                zlog.warn("Skipping invalid env entry (empty key or value): {s}", .{s});
                continue;
            }
            const key = s[0..eq_idx];
            const value = s[eq_idx + 1 ..];
            try env_map.put(key, value);
        }
        child.env_map = env_map;
    }

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

// Spawn a child process and wait for it to complete.
pub fn executeCommandSync(allocator: std.mem.Allocator, args: []string, cwd: ?string, env: ?[]string) !void {
    var child = try executeCommandAsync(allocator, args, cwd, env);
    const result = try child.wait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                return error.CommandFailed;
            }
        },
        else => {},
    }
}
