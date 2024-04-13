const std = @import("std");
const Video = @import("yt/video.zig").Video;
const allocator = std.testing.allocator;

test "check leaks" {
    var video = try Video.fetch(allocator, "ByZzz-sxV_c");
    defer video.dealloc();

    var stream_info = try video.fetchStreamInfo();
    defer stream_info.dealloc();
}
