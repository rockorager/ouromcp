const std = @import("std");
const j = @import("json.zig");
const fs = @import("fs.zig");
const c = fs.c;
pub const max_apps = 64;
pub const Entry = struct { id: []const u8, endpoint: []const u8, tools: []const u8, key: [64]u8 };

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    return true;
}
pub fn validPath(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, 0) != null) return false;
    return true;
}
pub fn validateTools(tools: j.V) !void {
    if (tools != .array or tools.array.items.len > 512) return error.InvalidCatalog;
    for (tools.array.items, 0..) |tool, index| {
        const name = j.str(j.get(tool, "name")) orelse return error.InvalidCatalog;
        if (name.len == 0 or name.len > 128 or j.get(tool, "inputSchema") != .object) return error.InvalidCatalog;
        if (j.get(tool, "description") != .null and j.get(tool, "description") != .string) return error.InvalidCatalog;
        for (tools.array.items[0..index]) |prior| if (j.eq(j.get(prior, "name"), name)) return error.DuplicateTool;
    }
}
pub fn encodeTools(a: std.mem.Allocator, input: j.V) ![]u8 {
    try validateTools(input);
    var tools = input;
    j.canonical(&tools);
    std.mem.sort(j.V, tools.array.items, {}, struct {
        fn less(_: void, x: j.V, y: j.V) bool {
            return std.mem.lessThan(u8, j.str(j.get(x, "name")).?, j.str(j.get(y, "name")).?);
        }
    }.less);
    return j.encode(a, tools);
}
fn descriptor(a: std.mem.Allocator, bytes: []const u8, id: []const u8) !j.V {
    const parsed = try j.parse(a, bytes);
    const v = parsed.value;
    if (j.int(j.get(v, "schema_version")) != 1 or !j.eq(j.get(v, "application_id"), id)) return error.InvalidDescriptor;
    if (!validPath(j.str(j.get(j.get(v, "endpoint"), "runtime_path")) orelse return error.InvalidDescriptor)) return error.InvalidDescriptor;
    try validateTools(j.get(v, "tools"));
    return v;
}
fn live(a: std.mem.Allocator, runtime: j.V) bool {
    const pid = j.int(j.get(runtime, "pid")) orelse return false;
    if (pid <= 0 or pid > std.math.maxInt(i32)) return false;
    const ticks = j.str(j.get(runtime, "start_ticks")) orelse return false;
    if (ticks.len == 0) return false;
    for (ticks) |ch| if (!std.ascii.isDigit(ch)) return false;
    const path = std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid}) catch return false;
    const fd = c.open(fs.z(a, path) catch return false, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_uid != c.getuid()) return false;
    const bytes = fs.readFd(a, fd) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return false;
    var fields = std.mem.tokenizeAny(u8, bytes[close + 1 ..], " \n");
    var index: usize = 3;
    while (fields.next()) |field| : (index += 1) {
        if (index == 3 and (std.mem.eql(u8, field, "Z") or std.mem.eql(u8, field, "X"))) return false;
        if (index == 22) return std.mem.eql(u8, field, ticks);
    }
    return false;
}
pub fn scan(a: std.mem.Allocator, filters: []const []const u8, context: []const u8) ![]Entry {
    const home = fs.env("HOME") orelse "/nonexistent";
    const data_home = fs.env("XDG_DATA_HOME") orelse try std.fmt.allocPrint(a, "{s}/.local/share", .{home});
    const data_dirs = fs.env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(a, data_home);
    var dirs = std.mem.splitScalar(u8, data_dirs, ':');
    while (dirs.next()) |root| try roots.append(a, root);
    var seen: std.StringHashMap(void) = .init(a);
    var entries: std.ArrayList(Entry) = .empty;
    const runtime = fs.env("XDG_RUNTIME_DIR") orelse "";
    const runtime_dir = fs.directory(a, runtime, "ouro/mcp/apps", false) catch -1;
    defer if (runtime_dir >= 0) {
        _ = c.close(runtime_dir);
    };
    var visited: usize = 0;
    var read_bytes: usize = 0;
    for (roots.items) |root| {
        if (!std.fs.path.isAbsolute(root)) continue;
        const path = try std.fmt.allocPrint(a, "{s}/ouro/mcp/apps", .{root});
        const dir = c.opendir(try fs.z(a, path)) orelse continue;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |item| {
            visited += 1;
            if (visited > 4096) return error.DiscoveryCapacity;
            const filename = std.mem.sliceTo(item.*.d_name[0..], 0);
            if (!std.mem.endsWith(u8, filename, ".json")) continue;
            const id = filename[0 .. filename.len - 5];
            if (!validId(id) or seen.contains(id)) continue;
            try seen.put(try a.dupe(u8, id), {});
            if (filters.len != 0) {
                var permitted = false;
                for (filters) |filter| if (std.mem.eql(u8, filter, id)) {
                    permitted = true;
                };
                if (!permitted) continue;
            }
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const origin = try std.fmt.allocPrint(sa, "{s}/{s}", .{ path, filename });
            const bytes = fs.read(sa, origin) catch |err| {
                if (err == error.Oversize) read_bytes += j.limit;
                if (read_bytes > 16 * 1024 * 1024) return error.DiscoveryCapacity;
                continue;
            };
            read_bytes += bytes.len;
            if (read_bytes > 16 * 1024 * 1024) return error.DiscoveryCapacity;
            const installed = descriptor(sa, bytes, id) catch continue;
            const endpoint = j.str(j.get(j.get(installed, "endpoint"), "runtime_path")).?;
            var selected = installed;
            var override: []const u8 = "";
            if (runtime_dir >= 0) override_block: {
                const candidate = fs.readAt(sa, runtime_dir, filename) catch break :override_block;
                const value = descriptor(sa, candidate, id) catch break :override_block;
                if (!j.eq(j.get(j.get(value, "endpoint"), "runtime_path"), endpoint) or !live(sa, j.get(value, "runtime"))) break :override_block;
                selected = value;
                override = candidate;
            }
            if (entries.items.len == max_apps) return error.DiscoveryCapacity;
            const key_input = try std.fmt.allocPrint(sa, "{s}\x00{s}\x00{s}\x00{s}\x00{s}\x00{s}", .{ origin, bytes, override, runtime, j.version, context });
            try entries.append(a, .{ .id = try a.dupe(u8, id), .endpoint = try a.dupe(u8, endpoint), .tools = try encodeTools(a, j.get(selected, "tools")), .key = j.hash(key_input) });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);
    return entries.toOwnedSlice(a);
}

test "runtime path and app id boundaries" {
    try std.testing.expect(validId("dev.ourokit.contacts"));
    try std.testing.expect(!validId(".."));
    try std.testing.expect(validPath("ourokit/apps/dev.test"));
    for ([_][]const u8{ "/foo", "foo//bar", "foo/../bar", "foo/", "" }) |bad| try std.testing.expect(!validPath(bad));
}
