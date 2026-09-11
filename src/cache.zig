const std = @import("std");
const j = @import("json.zig");
const fs = @import("fs.zig");
const c = fs.c;
const catalog = @import("catalog.zig");
pub const Cache = struct {
    dir: c_int = -1,
    pub fn init(a: std.mem.Allocator) Cache {
        const root = fs.env("XDG_CACHE_HOME") orelse (std.fmt.allocPrint(a, "{s}/.cache", .{fs.env("HOME") orelse "/nonexistent"}) catch return .{});
        return .{ .dir = fs.directory(a, root, "ouro/mcp", true) catch -1 };
    }
    pub fn name(a: std.mem.Allocator, key: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}.{s}", .{ key, suffix });
    }
    pub fn epoch(self: Cache, a: std.mem.Allocator, key: []const u8) []const u8 {
        if (self.dir < 0) return "";
        return fs.readAt(a, self.dir, name(a, key, "epoch") catch return "!") catch "";
    }
    pub fn invalidate(self: Cache, a: std.mem.Allocator, key: []const u8) !void {
        if (self.dir < 0) return;
        const token = try std.fmt.allocPrint(a, "{x}", .{fs.random()});
        try fs.atomic(a, self.dir, try name(a, key, "epoch"), token);
    }
    pub fn load(self: Cache, a: std.mem.Allocator, key: []const u8) ![]const u8 {
        if (self.dir < 0) return error.CacheMiss;
        const before = self.epoch(a, key);
        const bytes = try fs.readAt(a, self.dir, try name(a, key, "json"));
        const parsed = try j.parse(a, bytes);
        const v = parsed.value;
        const expires = j.int(j.get(v, "expires")) orelse return error.CacheMiss;
        if (expires <= fs.now() or !j.eq(j.get(v, "epoch"), before) or !std.mem.eql(u8, before, self.epoch(a, key))) return error.CacheMiss;
        if (!j.eq(j.get(v, "cacheScope"), "public") and !j.eq(j.get(v, "cacheScope"), "private")) return error.CacheMiss;
        try catalog.validateTools(j.get(v, "tools"));
        return j.encode(a, j.get(v, "tools"));
    }
    pub fn lock(self: Cache, a: std.mem.Allocator, key: []const u8) !c_int {
        if (self.dir < 0) return -1;
        const fd = c.openat(self.dir, try fs.z(a, try name(a, key, "lock")), c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK, @as(c_uint, 0o600));
        if (fd < 0) return error.CacheUnavailable;
        errdefer _ = c.close(fd);
        if (!fs.secure(fd)) return error.CacheUnavailable;
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.LockBusy;
        return fd;
    }
    pub fn store(self: Cache, a: std.mem.Allocator, key: []const u8, epoch_value: []const u8, tools: j.V, ttl: i64, scope: j.V) !void {
        if (self.dir < 0 or !std.mem.eql(u8, epoch_value, self.epoch(a, key))) return;
        if (!j.eq(scope, "public") and !j.eq(scope, "private")) return;
        // Only this UID and the identical effective bridge context share private entries.
        const bounded_ttl: u64 = @intCast(@min(@max(ttl, 0), 30 * 86400000));
        const jitter = if (bounded_ttl > 0) fs.random() % (bounded_ttl / 10 + 1) else 0;
        const expires = fs.now() + @as(i64, @intCast(bounded_ttl - jitter));
        const value = try j.obj(a, .{ .{ "expires", j.n(expires) }, .{ "epoch", j.s(epoch_value) }, .{ "cacheScope", scope }, .{ "tools", tools } });
        const bytes = try j.encode(a, value);
        if (bytes.len > j.limit) return;
        try fs.atomic(a, self.dir, try name(a, key, "json"), bytes);
        // A concurrent invalidation after the check is harmless: readers check epochs.
    }
};
