const std = @import("std");
const Video = @import("yt/video.zig").Video;

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    var video = try Video.fetch(allocator, args.next() orelse return);
    defer video.dealloc();

    var stream_info = try video.fetchStreamInfo();
    defer stream_info.dealloc();

    for (video.related.items) |related| {
        std.debug.print("related {{ title: {s}, id {s} }}\n", .{ related.title, related.id });
    }

    for (stream_info.list.items) |stream| {
        std.debug.print("video: {{ video: {any}, audio: {any}, url: {s} }}\n", .{ stream.quality, stream.audio_quality, stream.url });
    }
}
