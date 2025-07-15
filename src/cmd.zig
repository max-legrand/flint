const std = @import("std");
const string = []const u8;

// Spawn a child process and return a handle to it.
pub fn executeCommandAsync(allocator: std.mem.Allocator, args: []string) !std.process.Child {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

// Spawn a child process and wait for it to complete.
pub fn executeCommandSync(allocator: std.mem.Allocator, args: []string) !void {
    var child = try executeCommandAsync(allocator, args);
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
