const std = @import("std");

pub const Inclusion = enum {
    none,
    left,
    right,
    both,
};

pub fn findBetween(haystack: []const u8, left: []const u8, right: ?[]const u8, inclusion: Inclusion) ?[]const u8 {
    var start = std.mem.indexOf(u8, haystack, left) orelse return null;
    var end = haystack.len;

    if (right) |value| {
        end = std.mem.indexOfPos(u8, haystack, start + left.len, value) orelse return null;
    }

    switch (inclusion) {
        .none => {
            start += left.len;
        },

        .left => {},

        .right => {
            if (right) |value| {
                start += left.len;
                end += value.len;
            }
        },

        .both => {
            if (right) |value| {
                end += value.len;
            }
        },
    }

    return haystack[start..end];
}
