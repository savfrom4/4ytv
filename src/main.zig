const std = @import("std");
const Video = @import("yt/video.zig").Video;

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var video = try Video.fetch(allocator, "jL_15ZCjLoU");
    defer video.dealloc();

    var stream_info = try video.fetchStreamInfo();
    defer stream_info.dealloc();

    for (stream_info.list.items) |stream| {
        std.debug.print("{s}\n", .{stream.url});
    }
}
