const std = @import("std");
const cs = @import("constants.zig");
const js = @import("duktape");

pub const Video = struct {
    // External
    id: []const u8,
    title: []const u8,
    views: []const u8,

    // Internal
    allocator: std.mem.Allocator,
    vm: js.Context,
    player_url: []const u8,
    player: bool,
    decipher_func: ?[]const u8,
    ncode_func: ?[]const u8,

    pub fn fetch(allocator: std.mem.Allocator, id: []const u8) !Video {
        var vm = try js.Context.alloc();
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, cs.VIDEO_URL, .{id});
        defer allocator.free(url);

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .extra_headers = &cs.HEADERS,
            .response_storage = .{ .dynamic = &body },
        });

        if (result.status.class() != .success)
            return FetchError.InvalidVideo;

        // Initial data (video info, related...)
        var start = std.mem.indexOf(u8, body.items, "var ytInitialData =") orelse return FetchError.MissingPlayerData;
        var end = start + (std.mem.indexOf(u8, body.items[start..], "</script>") orelse return FetchError.MissingPlayerData);
        try vm.compile(body.items[start..end]);

        // Player data (streams)
        start = std.mem.indexOf(u8, body.items, "var ytInitialPlayerResponse =") orelse return FetchError.MissingPlayerData;
        end = start + (std.mem.indexOf(u8, body.items[start..], "</script>") orelse return FetchError.MissingPlayerData);
        try vm.compile(body.items[start..end]);

        // Player script url (obfuscated)
        start = 9 + (std.mem.indexOf(u8, body.items, "\"jsUrl\":\"/s/player/") orelse return FetchError.MissingPlayerData);
        end = start + (std.mem.indexOf(u8, body.items[start..], "\"") orelse return FetchError.MissingPlayerData);

        // Get data
        const title = try vm.eval("ytInitialData.contents.twoColumnWatchNextResults.results.results.contents[0].videoPrimaryInfoRenderer.title.runs[0].text") orelse return FetchError.MissingPlayerData;
        const views = try vm.eval("ytInitialData.contents.twoColumnWatchNextResults.results.results.contents[0].videoPrimaryInfoRenderer.viewCount.videoViewCountRenderer.viewCount.simpleText") orelse return FetchError.MissingPlayerData;

        return Video{
            .id = id, // i sure hope ID outlives this video struct
            .title = title.string,
            .views = views.string,

            .allocator = allocator,
            .vm = vm,

            .player_url = try std.fmt.allocPrint(allocator, "https://youtube.com{s}", .{body.items[start..end]}), // stored in body, so we need to dupe
            .player = false,
            .decipher_func = null,
            .ncode_func = null,
        };
    }

    const Self = @This();
    pub fn dealloc(self: Self) void {
        var _vm = self.vm;
        _vm.dealloc();

        self.allocator.free(self.player_url);
        if (self.decipher_func) |func| {
            self.allocator.free(func);
        }
        if (self.ncode_func) |func| {
            self.allocator.free(func);
        }
    }

    pub fn fetchStreamInfo(self: *Self) !StreamInfo {
        const value = try self.vm.eval("JSON.stringify(ytInitialPlayerResponse.streamingData)") orelse return FetchStreamError.StreamingDataUnavailable;
        switch (value) {
            .string => |str| {
                const streamingData = try std.json.parseFromSlice(std.json.Value, self.allocator, str, .{});
                defer streamingData.deinit();

                var streams = StreamInfo{
                    .allocator = self.allocator,
                    .list = std.ArrayList(StreamInfo.Stream).init(self.allocator),
                };

                var formats = streamingData.value.object.get("formats") orelse return FetchStreamError.MissingFormats;
                for (formats.array.items) |v| {
                    try streams.list.append(try parseStream(self, v.object));
                }

                formats = streamingData.value.object.get("adaptiveFormats") orelse return FetchStreamError.MissingFormats;
                for (formats.array.items) |v| {
                    try streams.list.append(try parseStream(self, v.object));
                }

                return streams;
            },

            else => return FetchStreamError.StreamingDataUnavailable,
        }
    }

    fn parseStream(self: *Self, object: std.json.ObjectMap) !StreamInfo.Stream {
        var url: []const u8 = undefined;
        if (object.get("url")) |value| {
            url = try std.Uri.unescapeString(self.allocator, value.string);
        } else {
            const sign = object.get("signatureCipher") orelse return ParseStreamError.MissingStreamData;
            url = try decodeStream(self, sign.string);
        }

        var mime_type: StreamInfo.Stream.MimeType = undefined;
        if (object.get("mimeType")) |value| {
            var iter = std.mem.split(u8, value.string, ";");
            mime_type = std.meta.stringToEnum(StreamInfo.Stream.MimeType, iter.first()) orelse return ParseStreamError.UnknownMimeType;
        }

        var quality: ?StreamInfo.Stream.VideoQuality = null;
        if (object.get("quality")) |value| {
            // youtube sets "little" quality for audio, so check for something else video related
            if (object.get("width")) |width| {
                quality = StreamInfo.Stream.VideoQuality{
                    .width = @intCast(width.integer),
                    .height = @intCast((object.get("height") orelse return ParseStreamError.UnknownVideoQuality).integer),
                    .fps = @intCast((object.get("fps") orelse return ParseStreamError.UnknownVideoQuality).integer),
                    .type = std.meta.stringToEnum(StreamInfo.Stream.VideoQuality.QualityType, value.string) orelse return ParseStreamError.UnknownVideoQuality,
                };
            }
        }

        var audio_quality: ?StreamInfo.Stream.AudioQuality = null;
        if (object.get("audioQuality")) |value| {
            audio_quality = StreamInfo.Stream.AudioQuality{
                .sample_rate = try std.fmt.parseInt(u32, (object.get("audioSampleRate") orelse return ParseStreamError.UnknownAudioQuality).string, 10),
                .channels = @intCast((object.get("audioChannels") orelse return ParseStreamError.UnknownAudioQuality).integer),
                .type = switch (std.meta.stringToEnum(enum {
                    AUDIO_QUALITY_LOW,
                    AUDIO_QUALITY_MEDIUM,
                    AUDIO_QUALITY_HIGH, // not sure?
                }, value.string) orelse return ParseStreamError.UnknownAudioQuality) {
                    .AUDIO_QUALITY_LOW => .low,
                    .AUDIO_QUALITY_MEDIUM => .medium,
                    .AUDIO_QUALITY_HIGH => .high,
                },
            };
        }

        return StreamInfo.Stream{
            .url = url,

            .itag = @intCast((object.get("itag") orelse return ParseStreamError.MissingStreamData).integer),
            .duration = try std.fmt.parseInt(u64, (object.get("approxDurationMs") orelse return ParseStreamError.MissingStreamData).string, 10),
            .birate = @intCast((object.get("bitrate") orelse return ParseStreamError.MissingStreamData).integer),

            .mime_type = mime_type,
            .quality = quality,
            .audio_quality = audio_quality,
        };
    }

    fn decodeStream(self: *Self, sign: []const u8) ![]const u8 {
        // if player script is not there we need to fetch & deobfuscate it too
        if (!self.player) {
            try fetchDeobfuscatePlayer(self);
        }

        // run decipher
        var start = 2 + (std.mem.indexOf(u8, sign, "s=") orelse return DecodePlayerError.InvalidCipher);
        var end = std.mem.indexOf(u8, sign[start..], "&") orelse return DecodePlayerError.InvalidCipher;

        const decipher_call = try std.fmt.allocPrint(self.allocator, "{s}(\"{s}\")", .{ self.decipher_func.?, sign[start..end] });
        const cipher = (try self.vm.eval(decipher_call) orelse return DecodePlayerError.InvalidCipher).string;

        start = 3 + (std.mem.indexOf(u8, sign, "sp=") orelse return DecodePlayerError.InvalidCipher);
        end = start + (std.mem.indexOf(u8, sign[start..], "&") orelse return DecodePlayerError.InvalidCipher);
        const sp = sign[start..end];

        start = 4 + (std.mem.indexOf(u8, sign, "url=") orelse return DecodePlayerError.InvalidCipher);
        const unescaped_url = try std.Uri.unescapeString(self.allocator, sign[start..]);
        defer self.allocator.free(unescaped_url);

        // Find ncode
        start = 2 + (std.mem.indexOf(u8, unescaped_url, "n=") orelse return DecodePlayerError.InvalidCipher);
        end = start + (std.mem.indexOf(u8, unescaped_url[start..], "&") orelse return DecodePlayerError.InvalidCipher);

        // run ncode
        const ncode_call = try std.fmt.allocPrint(self.allocator, "{s}(\"{s}\")", .{ self.ncode_func.?, unescaped_url[start..end] });
        defer self.allocator.free(ncode_call);

        const ncode = (try self.vm.eval(ncode_call) orelse return DecodePlayerError.InvalidCipher).string;
        return try std.fmt.allocPrint(self.allocator, "{s}&{s}={s}&n={s}", .{ unescaped_url, sp, cipher, ncode });
    }

    fn fetchDeobfuscatePlayer(self: *Self) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = self.player_url },
            .extra_headers = &cs.HEADERS,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = std.math.maxInt(usize), // unlimited
        });

        if (result.status.class() != .success)
            return FetchPlayerError.InvalidPlayerUrl;

        // Find the struct with functions
        var start = 14 + (std.mem.indexOf(u8, body.items, "a=a.split(\"\");") orelse return FetchPlayerError.DeobfuscationFailed);
        var end = start + (std.mem.indexOf(u8, body.items[start..], ".") orelse return FetchPlayerError.DeobfuscationFailed);
        std.debug.print("1 {s}\n", .{body.items[start..end]});

        const struct_name = try std.fmt.allocPrint(self.allocator, "var {s}={s}", .{ body.items[start..end], "{" });
        defer self.allocator.free(struct_name);

        start = std.mem.indexOf(u8, body.items, struct_name) orelse return FetchPlayerError.DeobfuscationFailed;
        end = 2 + start + (std.mem.indexOf(u8, body.items[start..], "};") orelse return FetchPlayerError.DeobfuscationFailed);
        try self.vm.compile(body.items[start..end]);
        std.debug.print("2 {s}\n", .{body.items[start..end]});

        // Find decipher function
        start = 25 + (std.mem.indexOf(u8, body.items, "a.set(\"alr\",\"yes\");c&&(c=") orelse return FetchPlayerError.DeobfuscationFailed);
        end = start + (std.mem.indexOf(u8, body.items[start..], "(decodeURIC") orelse return FetchPlayerError.DeobfuscationFailed);
        self.decipher_func = try self.allocator.dupe(u8, body.items[start..end]);

        const decipher_name = try std.fmt.allocPrint(self.allocator, "{s}=function(a)", .{body.items[start..end]});
        defer self.allocator.free(decipher_name);

        start = std.mem.indexOf(u8, body.items, decipher_name) orelse return FetchPlayerError.DeobfuscationFailed;
        end = 19 + start + (std.mem.indexOf(u8, body.items[start..], "return a.join(\"\")};") orelse return FetchPlayerError.DeobfuscationFailed);
        try self.vm.compile(body.items[start..end]);
        std.debug.print("3 {s}\n", .{body.items[start..end]});

        // Find ncode function
        start = 21 + (std.mem.indexOf(u8, body.items, "&&(b=a.get(\"n\"))&&(b=") orelse return FetchPlayerError.DeobfuscationFailed);
        end = (std.mem.indexOf(u8, body.items, "[0](b)") orelse return FetchPlayerError.DeobfuscationFailed);
        self.ncode_func = try self.allocator.dupe(u8, body.items[start..end]);

        const ncode_array = try std.fmt.allocPrint(self.allocator, "var {s}=[", .{body.items[start..end]});
        defer self.allocator.free(ncode_array);
        std.debug.print("4 {s}\n", .{body.items[start..end]});

        start = std.mem.indexOf(u8, body.items, ncode_array) orelse return FetchPlayerError.DeobfuscationFailed;
        end = 1 + start + (std.mem.indexOf(u8, body.items[start..], "]") orelse return FetchPlayerError.DeobfuscationFailed);
        try self.vm.compile(body.items[start..end]);

        start = ncode_array.len + (std.mem.indexOf(u8, body.items, ncode_array) orelse return FetchPlayerError.DeobfuscationFailed);
        end = start + (std.mem.indexOf(u8, body.items[start..], "]") orelse return FetchPlayerError.DeobfuscationFailed);
        std.debug.print("5 {s}\n", .{body.items[start..end]});

        const ncode_name = try std.fmt.allocPrint(self.allocator, "{s}=function(a)", .{body.items[start..end]});
        defer self.allocator.free(ncode_name);

        start = (std.mem.indexOf(u8, body.items, ncode_name) orelse return FetchPlayerError.DeobfuscationFailed);
        end = 19 + start + (std.mem.indexOf(u8, body.items[start..], "return b.join(\"\")};") orelse return FetchPlayerError.DeobfuscationFailed);
        try self.vm.compile(body.items[start..end]);

        std.debug.print("6 {s}\n", .{body.items[start..end]});
        self.player = true;
    }

    const FetchError = error{
        InvalidVideo,
        MissingPlayerData,
        UnknownMimeType,
    };

    const FetchPlayerError = error{
        InvalidPlayerUrl,
        DeobfuscationFailed,
    };

    const DecodePlayerError = error{
        InvalidCipher,
    };

    const FetchStreamError = error{
        StreamingDataUnavailable,
        MissingStreamingData,
        MissingFormats,
    };

    const ParseStreamError = error{
        UnknownMimeType,
        UnknownVideoQuality,
        UnknownAudioQuality,
        MissingStreamData,
    };
};

pub const StreamInfo = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Stream),

    const Self = @This();
    pub fn dealloc(self: *Self) void {
        for (self.list.items) |stream| {
            self.allocator.free(stream.url);
        }
        self.list.deinit();
    }

    const StreamPair = struct { video: Stream, audio: Stream };
    const Stream = struct {
        url: []const u8,

        itag: u16,
        duration: u64,
        birate: u32,

        mime_type: MimeType,
        quality: ?VideoQuality,
        audio_quality: ?AudioQuality,

        const VideoQuality = struct {
            width: u16,
            height: u16,
            fps: u16,
            type: QualityType,

            const QualityType = enum {
                none,
                tiny, // 144p
                small, // 240p
                medium, // 360p
                large, // 480p
                hd720, // 720p
                hd1080, // 1080p

                // TODO: add support for 2K+
            };
        };

        const AudioQuality = struct {
            sample_rate: u32,
            channels: u8,
            type: QualityType,

            const QualityType = enum {
                none,
                low,
                medium,
                high,
            };
        };

        const MimeType = enum {
            @"video/mp4",
            @"video/webm",
            @"audio/mp4",
            @"audio/webm",
        };
    };
};
