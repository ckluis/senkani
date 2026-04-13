// This is a comment
const std = @import("std");

const User = struct {
    name: []const u8,
    age: i32 = 42,
};

fn greet(user: User) void {
    std.debug.print("Hi, {s}!\n", .{user.name});
}

const pi: f64 = 3.14;
const ch: u8 = 'A';
