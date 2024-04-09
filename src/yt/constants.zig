const std = @import("std");

pub const SEARCH_URL = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false";
pub const VIDEO_URL = "https://www.youtube.com/watch?v={s}";

pub const HEADERS = [_]std.http.Header{
    .{ .name = "User-Agent", .value = "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0" },
    .{ .name = "Accept", .value = "*/*" },
    .{ .name = "Accept-Language", .value = "en-GB,en;q=0.5" },
    .{ .name = "Alt-Used", .value = "https://www.youtube.com" },

    .{ .name = "Sec-Fetch-Dest", .value = "empty" },
    .{ .name = "Sec-Fetch-Mode", .value = "same-origin" },
    .{ .name = "Sec-Fetch-Site", .value = "same-origin" },

    .{ .name = "X-Origin", .value = "https://www.youtube.com" },
    .{ .name = "X-Youtube-Bootstrap-Logged-In", .value = "false" },
    .{ .name = "X-Youtube-Client-Name", .value = "1" },
    .{ .name = "X-Youtube-Client-Version", .value = "2.20240403.07.00" },
};
