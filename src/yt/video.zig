const std = @import("std");
const js = @import("duktape");
const cs = @import("constants.zig");
const utils = @import("utils.zig");

pub const PartialVideo = struct {
    id: []const u8,
    title: []const u8,
    views: []const u8,
    thumbnail_url: []const u8,
};

pub const Video = struct {
    // External
    id: []const u8,
    title: []const u8,
    views: []const u8,
    related: std.ArrayList(PartialVideo),

    // Internal
    allocator: std.mem.Allocator,
    vm: js.Context,
    player_url: []const u8,
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

        // Load player data into js engine
        try vm.compile(utils.findBetween(body.items, "var ytInitialData =", "</script>", .left) orelse return FetchError.MissingPlayerData);
        try vm.compile(utils.findBetween(body.items, "var ytInitialPlayerResponse =", "</script>", .left) orelse return FetchError.MissingPlayerData);

        // Url of the player script (contains decipher and ncode functions)
        const player_url = utils.findBetween(body.items, "\"jsUrl\":\"/s/player/", "\"", .none) orelse return FetchError.MissingPlayerData;
        const title = try vm.eval("ytInitialData.contents.twoColumnWatchNextResults.results.results.contents[0].videoPrimaryInfoRenderer.title.runs[0].text") orelse return FetchError.MissingPlayerData;
        const views = try vm.eval("ytInitialData.contents.twoColumnWatchNextResults.results.results.contents[0].videoPrimaryInfoRenderer.viewCount.videoViewCountRenderer.viewCount.simpleText") orelse return FetchError.MissingPlayerData;
        
        const secondary_length = (try vm.eval("ytInitialData.contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results.length") orelse return FetchError.MissingPlayerData).number;
        var related = std.ArrayList(PartialVideo).init(allocator);
        for(0..@intFromFloat(secondary_length)) |idx| {
            const query = try std.fmt.allocPrint(allocator, "JSON.stringify(ytInitialData.contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results[{d}])", .{idx});
            defer allocator.free(query);
            
            const json = try std.json.parseFromSlice(std.json.Value, allocator, (try vm.eval(query) orelse return FetchError.MissingPlayerData).string, .{});
            defer json.deinit();  
//            json.value.dump();

            const root = (json.value.object.get("compactVideoRenderer") orelse continue).object;
            try related.append(PartialVideo {
                .id = root.get("videoId").?.string,
                .title = root.get("title").?.object.get("simpleText").?.string,
                .thumbnail_url = root.get("thumbnail").?.object.get("thumbnails").?.array.items[0].object
                    .get("url").?.string,
                .views = root.get("viewCountText").?.object.get("simpleText").?.string,
            });
        }

        return Video{
            .id = id, // i sure hope ID outlives this video struct
            .title = title.string,
            .views = views.string,
            .related = related,

            .allocator = allocator,
            .vm = vm,

            .player_url = try std.fmt.allocPrint(allocator, "https://youtube.com/s/player/{s}", .{player_url}), // stored in body, so we need to dupe
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
        std.debug.print("stream is encoded, decoing needed...\n", .{});

        // if player script is not there we need to fetch & deobfuscate it too
        if (self.decipher_func == null or self.ncode_func == null) {
            try fetchDeobfuscatePlayer(self);
        }

        // Url is the last element... probably... most of the times?
        const url = try std.Uri.unescapeString(self.allocator, utils.findBetween(sign, "url=", null, .none) orelse return DecodePlayerError.InvalidCipher);
        defer self.allocator.free(url);

        // Find everything we need
        const cipher = utils.findBetween(sign, "s=", "&", .none) orelse return DecodePlayerError.InvalidCipher;
        const sp = utils.findBetween(sign, "sp=", "&", .none) orelse return DecodePlayerError.InvalidCipher;
        const ncode = utils.findBetween(url, "&n=", "&", .none) orelse return DecodePlayerError.InvalidCipher;

        // Get decipher result & dencode result
        const decipher = try self.allocator.dupe(u8, ((try self.vm.call(self.decipher_func.?, .{cipher})) orelse return DecodePlayerError.InvalidCipher).string);
        defer self.allocator.free(decipher);
        std.debug.print("decipher: {s}\n", .{decipher});

        const dencode = try self.allocator.dupe(u8, ((try self.vm.call(self.ncode_func.?, .{ncode})) orelse return DecodePlayerError.InvalidCipher).string);
        defer self.allocator.free(dencode);
        std.debug.print("dencode: {s}\n", .{dencode});

        return try std.fmt.allocPrint(self.allocator, "{s}&{s}={s}&n={s}", .{ url, sp, decipher, dencode });
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

        // Find the structure containg the function & compile it
        const struct_name = try std.fmt.allocPrint(self.allocator, "var {s}={{", .{
            utils.findBetween(body.items, "a=a.split(\"\");", ".", .none) orelse return FetchPlayerError.DeobfuscationFailed,
        });

        try self.vm.compile(
            utils.findBetween(body.items, struct_name, "};", .both) orelse return FetchPlayerError.DeobfuscationFailed,
        );
        self.allocator.free(struct_name);

        // Find decipher function name
        self.decipher_func = try self.allocator.dupe(
            u8,
            utils.findBetween(body.items, "a.set(\"alr\",\"yes\");c&&(c=", "(decodeURIC", .none) orelse return FetchPlayerError.DeobfuscationFailed,
        );

        // Find decipher function body & compile it
        const decipher_name = try std.fmt.allocPrint(self.allocator, "{s}=function(a)", .{self.decipher_func.?});
        const decipher_body = try std.fmt.allocPrint(self.allocator, "var {s}", .{
            utils.findBetween(body.items, decipher_name, "return a.join(\"\")};", .both) orelse return FetchPlayerError.DeobfuscationFailed,
        });

        try self.vm.compile(decipher_body);
        self.allocator.free(decipher_name);
        self.allocator.free(decipher_body);

        // Find array that contains ncode function name & compile it
        const ncode_array_name = try std.fmt.allocPrint(self.allocator, "var {s}=[", .{
            utils.findBetween(body.items, "&&(b=a.get(\"n\"))&&(b=", "[0](b)", .none) orelse return FetchPlayerError.DeobfuscationFailed,
        });

        const ncode_array = utils.findBetween(body.items, ncode_array_name, "]", .both) orelse return FetchPlayerError.DeobfuscationFailed;
        self.allocator.free(ncode_array_name);

        try self.vm.compile(ncode_array);

        // Find ncode function name in that array
        self.ncode_func = try self.allocator.dupe(
            u8,
            utils.findBetween(ncode_array, "[", "]", .none) orelse return FetchPlayerError.DeobfuscationFailed,
        );

        // Find ncode function body & compile it
        const ncode_function_name = try std.fmt.allocPrint(self.allocator, "{s}=function(a)", .{
            self.ncode_func.?,
        });

        const ncode_function_body = try std.fmt.allocPrint(self.allocator, "var {s}", .{
            utils.findBetween(body.items, ncode_function_name, "return b.join(\"\")};", .both) orelse return FetchPlayerError.DeobfuscationFailed,
        });

        try self.vm.compile(ncode_function_body);
        self.allocator.free(ncode_function_name);
        self.allocator.free(ncode_function_body);
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
