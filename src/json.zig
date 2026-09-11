const std = @import("std");
pub const V = std.json.Value;
pub const limit = 256 * 1024;
pub const version = "2026-07-28";
pub const version_key = "io.modelcontextprotocol/protocolVersion";
pub const caps_key = "io.modelcontextprotocol/clientCapabilities";
pub const sub_key = "io.modelcontextprotocol/subscriptionId";

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(V) {
    if (bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJson;
    // Bound parser recursion independently of the wire bound.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                quoted = false;
            }
        } else switch (ch) {
            '"' => quoted = true,
            '[', '{' => {
                depth += 1;
                if (depth > 128) return error.InvalidJson;
            },
            ']', '}' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    return std.json.parseFromSlice(V, a, bytes, .{ .allocate = .alloc_always, .parse_numbers = false, .max_value_len = limit });
}
pub fn get(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: V) ?[]const u8 {
    return if (v == .string) v.string else null;
}
pub fn eq(v: V, expected: []const u8) bool {
    return if (str(v)) |text| std.mem.eql(u8, text, expected) else false;
}
pub fn s(text: []const u8) V {
    return .{ .string = text };
}
pub fn n(value: i64) V {
    return .{ .integer = value };
}
pub fn obj(a: std.mem.Allocator, fields: anytype) !V {
    var map: std.json.ObjectMap = .empty;
    inline for (fields) |field| try map.put(a, field[0], field[1]);
    return .{ .object = map };
}
pub fn arr(a: std.mem.Allocator, values: []const V) !V {
    var list: std.array_list.Managed(V) = .init(a);
    try list.appendSlice(values);
    return .{ .array = list };
}
pub fn encode(a: std.mem.Allocator, v: V) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}
pub fn canonical(v: *V) void {
    switch (v.*) {
        .object => |*map| {
            map.sort(struct {
                keys: []const []const u8,
                pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
                    return std.mem.lessThan(u8, ctx.keys[x], ctx.keys[y]);
                }
            }{ .keys = map.keys() });
            for (map.values()) |*child| canonical(child);
        },
        .array => |*items| for (items.items) |*child| canonical(child),
        else => {},
    }
}
pub fn int(v: V) ?i64 {
    return switch (v) {
        .integer => v.integer,
        .number_string => std.fmt.parseInt(i64, v.number_string, 10) catch null,
        else => null,
    };
}
pub fn validId(v: V) bool {
    return v == .string or v == .number_string or v == .integer;
}
pub fn sameId(a: std.mem.Allocator, x: V, y: V) !bool {
    // IDs never pass through floating point, including huge integers.
    const xx = try encode(a, x);
    const yy = try encode(a, y);
    return std.mem.eql(u8, xx, yy);
}
pub fn meta(a: std.mem.Allocator) !V {
    return obj(a, .{ .{ version_key, s(version) }, .{ caps_key, try obj(a, .{}) }, .{ "io.modelcontextprotocol/clientInfo", try obj(a, .{ .{ "name", s("ouro-mcp") }, .{ "version", s("0.1.0") } }) } });
}
pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn toolName(a: std.mem.Allocator, app: []const u8, name: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ app, name });
    const hex = hash(input);
    return std.fmt.allocPrint(a, "ouro_{s}", .{hex});
}

test "numeric lexemes survive parsing and encoding" {
    const input = "[1.0,1e0,999999999999999999999999999999999999,1e999,-0.125]";
    const p = try parse(std.testing.allocator, input);
    defer p.deinit();
    const out = try encode(std.testing.allocator, p.value);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}
