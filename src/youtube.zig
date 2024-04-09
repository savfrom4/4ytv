const std = @import("std");

const InternalRendererType = enum {
    shelfRenderer,
    reelShelfRenderer,
    videoRenderer,
    channelRenderer,
};

pub const Client = struct {
    client: std.http.Client,
    headers: std.http.Headers,
    allocator: std.mem.Allocator,

    const Self = @This();
    pub fn init(allocator: std.mem.Allocator) !Self {
        const client = std.http.Client{ .allocator = allocator };
        var headers = std.http.Headers.init(allocator);

        return Client{
            .client = client,
            .headers = headers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.headers.deinit();
    }

    pub fn search(self: *Self, query: []const u8) !SearchResults {
        // Setting up request urls
        const query_without_spaces = try std.mem.replaceOwned(u8, self.allocator, query, " ", "+");
        defer self.allocator.free(query_without_spaces);

        const original_url = try std.fmt.allocPrint(self.allocator, "https://www.youtube.com/results?search_query={s}", .{query_without_spaces});
        defer self.allocator.free(original_url);

        const graft_url = try std.fmt.allocPrint(self.allocator, "/results?search_query={s}", .{query_without_spaces});
        defer self.allocator.free(graft_url);

        const webSearchbox_stats_url = try std.fmt.allocPrint(self.allocator, "/search?oq={s}&gs_l=youtube.3..0i512k1l14.765.3274.0.3563.16.10.0.0.0.0.529.1421.2-2j1j0j1.4.0....0...1ac.1.64.youtube..12.4.1421...0i512i433i131k1.0.gv05FyCM8oU", .{query});
        defer self.allocator.free(webSearchbox_stats_url);

        // Make a request
        var request = try self.client.request(.POST, try std.Uri.parse(YTSEARCH_URL), self.headers, .{});
        defer request.deinit();

        const requestBody = try std.json.stringifyAlloc(self.allocator, .{
            .adSignalsInfo = .{},
            .clickTracking = .{},

            .context = .{
                .client = .{
                    .acceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                    .browserName = "Firefox",
                    .browserVersion = "124.0",
                    .clientFormFactor = "UNKNOWN_FORM_FACTOR",
                    .clientName = "WEB",
                    .clientVersion = "2.20240403.07.00",

                    .configInfo = .{
                        .appInstallData = "",
                    },

                    .deviceMake = "",
                    .deviceModel = "",
                    .gl = "GB",
                    .hl = "en",

                    .mainAppWebInfo = .{
                        .graftUrl = graft_url,
                        .isWebNativeShareAvailable = false,
                        .pwaInstallabilityStatus = "PWA_INSTALLABILITY_STATUS_UNKNOWN",
                        .webDisplayMode = "WEB_DISPLAY_MODE_BROWSER",
                    },

                    .originalUrl = original_url,
                    .osName = "X11",
                    .osVersion = "",
                    .platform = "DESKTOP",
                    .remoteHost = "",
                    .screenDensityFloat = 1,
                    .screenHeightPoints = 203,
                    .screenPixelDensity = 1,
                    .screenWidthPoints = 1920,
                    .timeZone = "Europe/London",
                    .userAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0,gzip(gfe)",
                    .userInterfaceTheme = "USER_INTERFACE_THEME_DARK",
                    .utcOffsetMinutes = 60,
                },

                .request = .{
                    .consistencyTokenJars = .{},
                    .internalExperimentFlags = .{},
                    .useSsl = true,
                },

                .user = .{
                    .lockedSafetyMode = false,
                },
            },

            .query = query,
            .webSearchboxStatsUrl = webSearchbox_stats_url,
        }, .{});

        request.transfer_encoding = .chunked;
        try request.start();
        try request.writeAll(requestBody);
        try request.finish();
        try request.wait();

        const body = try request.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
        var json = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        const root: std.ArrayList(std.json.Value) = json.value.object.get("contents").?.object.get("twoColumnSearchResultsRenderer").?.object.get("primaryContents").?.object.get("sectionListRenderer").?.object.get("contents").?.array.items[0].object.get("itemSectionRenderer").?.object.get("contents").?.array;
        var list = std.ArrayList(SearchResult).init(self.allocator);

        for (root.items) |item| {
            const keys = item.object.keys();

            if (keys.len == 0)
                continue;

            switch (std.meta.stringToEnum(InternalRendererType, keys[0]).?) {
                .videoRenderer => {
                    var object: std.json.ObjectMap = item.object.values()[0].object;

                    try list.append(SearchResult{
                        .video = .{
                            .id = object.get("videoId").?.string,
                            .thumbnail_url = object.get("thumbnail").?.object.get("thumbnails").?.array.items[0].object.get("url").?.string,
                            .title = object.get("title").?.object.get("runs").?.array.items[0].object.get("text").?.string,
                        },
                    });
                },
                .channelRenderer => {},

                else => continue,
            }
        }

        return SearchResults{
            .allocator = self.allocator,
            .raw_body = body,
            .json = json,
            .list = list,
        };
    }

    pub fn fetch_video_test(self: *Self, url: []const u8) !void {
        var request = try self.client.request(.GET, try std.Uri.parse(url), self.headers, .{});
        defer request.deinit();

        try request.start();
        try request.finish();
        try request.wait();

        std.debug.print("{any}", .{request.response});
        std.debug.print("{s}", .{try request.reader().readAllAlloc(self.allocator, std.math.maxInt(usize))});
    }
};

pub const SearchResults = struct {
    allocator: std.mem.Allocator,
    raw_body: []u8,
    json: std.json.Parsed(std.json.Value),
    list: std.ArrayList(SearchResult),

    pub fn deinit(self: *@This()) void {
        self.json.deinit();
        self.allocator.free(self.raw_body);
    }
};

pub const SearchResult = union(enum) {
    video: Video,
    channel: struct {},
};

pub const Video = struct {
    title: []const u8,
    id: []const u8,
    thumbnail_url: []const u8,

    const Self = @This();
    pub fn get_url(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "https://www.youtube.com/watch?v={s}", .{self.id});
    }
};
