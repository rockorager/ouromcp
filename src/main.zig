const std = @import("std");
const linux = std.os.linux;
const j = @import("json.zig");
const fs = @import("fs.zig");
const c = fs.c;
const catalog = @import("catalog.zig");
const Cache = @import("cache.zig").Cache;
const g = std.heap.c_allocator;
const max_requests = 128;
const max_subscriptions = 32;
const timeout_ms = 10000;
const timer_tag = 10000;
const cancel_tag = 10001;

const Peer = struct {
    fd: c_int = -1,
    closing: bool = false,
    reading: bool = false,
    writing: bool = false,
    connecting: bool = false,
    cancellations: usize = 0,
    read_buffer: [16384]u8 = undefined,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList([]u8) = .empty,
    output_bytes: usize = 0,
    offset: usize = 0,
    write_started: i64 = 0,
    frame_started: i64 = 0,
    address: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 },
};
const App = struct {
    id: ?[]const u8 = null,
    endpoint: []const u8 = "",
    baseline: []const u8 = "[]",
    tools: []const u8 = "[]",
    key: [64]u8 = undefined,
    present: bool = false,
    state: enum { offline, connecting, subscribing, ready } = .offline,
    listen_id: i64 = 0,
    subscribed: bool = false,
    list_id: i64 = 0,
    want_refresh: bool = false,
    dirty: bool = false,
    deadline: i64 = 0,
    lock_fd: c_int = -1,
    epoch: []const u8 = "",
    pages: []const u8 = "[]",
    page_count: usize = 0,
    ttl: i64 = 0,
    scope: []const u8 = "private",
};
const Request = struct {
    doc: std.json.Parsed(j.V),
    app: ?usize,
    name: []const u8,
    downstream: i64 = 0,
    deadline: i64,
    fn id(self: Request) j.V {
        return j.get(self.doc.value, "id");
    }
};
const Bridge = struct {
    ring: linux.IoUring,
    peers: [catalog.max_apps + 1]Peer = @splat(.{}),
    apps: [catalog.max_apps]App = @splat(.{}),
    requests: [max_requests]?Request = @splat(null),
    subscriptions: [max_subscriptions]?[]const u8 = @splat(null),
    cache: Cache,
    filters: []const []const u8,
    context: []const u8,
    next_id: i64 = 1,
    next_scan: i64 = 0,
    catalog_error: bool = false,
    eof: bool = false,
    exit_at: i64 = 0,
    tick: linux.kernel_timespec = .{ .sec = 0, .nsec = 100000000 },

    fn newId(self: *Bridge) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
    fn send(self: *Bridge, a: std.mem.Allocator, peer: usize, value: j.V) !void {
        const bytes = try j.encode(a, value);
        if (bytes.len + 1 > j.limit) return error.MessageCapacity;
        const p = &self.peers[peer];
        if (p.closing or p.fd < 0) return error.Disconnected;
        if (p.output.items.len >= 128 or p.output_bytes + bytes.len + 1 > 1024 * 1024) return error.OutputCapacity;
        const line = try g.alloc(u8, bytes.len + 1);
        @memcpy(line[0..bytes.len], bytes);
        line[bytes.len] = '\n';
        try p.output.append(g, line);
        p.output_bytes += line.len;
        try self.write(peer);
    }
    fn write(self: *Bridge, peer: usize) !void {
        const p = &self.peers[peer];
        if (p.writing or p.connecting or p.closing or p.output.items.len == 0) return;
        _ = try self.ring.write(@intCast(peer * 4 + 2), if (peer == 0) 1 else p.fd, p.output.items[0][p.offset..], std.math.maxInt(u64));
        p.writing = true;
        if (p.offset == 0) p.write_started = fs.monotonic();
    }
    fn read(self: *Bridge, peer: usize) !void {
        const p = &self.peers[peer];
        if (p.reading or p.closing or p.fd < 0 or (peer == 0 and self.eof)) return;
        _ = try self.ring.read(@intCast(peer * 4 + 1), p.fd, .{ .buffer = &p.read_buffer }, std.math.maxInt(u64));
        p.reading = true;
    }
    fn result(self: *Bridge, a: std.mem.Allocator, id: j.V, value: j.V) !void {
        try self.send(a, 0, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "id", id }, .{ "result", value } }));
    }
    fn rpcError(self: *Bridge, a: std.mem.Allocator, id: j.V, code: i64, message: []const u8) !void {
        try self.send(a, 0, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "id", id }, .{ "error", try j.obj(a, .{ .{ "code", j.n(code) }, .{ "message", j.s(message) } }) } }));
    }
    fn downstream(self: *Bridge, a: std.mem.Allocator, index: usize, id: i64, method: []const u8, params: j.V) !void {
        var p = params;
        try p.object.put(a, "_meta", try j.meta(a));
        try self.send(a, index + 1, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "id", j.n(id) }, .{ "method", j.s(method) }, .{ "params", p } }));
    }
    fn cancel(self: *Bridge, a: std.mem.Allocator, index: usize, id: i64) !void {
        try self.send(a, index + 1, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "method", j.s("notifications/cancelled") }, .{ "params", try j.obj(a, .{.{ "requestId", j.n(id) }}) } }));
    }
    fn notify(self: *Bridge, a: std.mem.Allocator) !void {
        if (self.eof) return;
        for (self.subscriptions) |sub| if (sub) |bytes| {
            const parsed = try j.parse(a, bytes);
            try self.send(a, 0, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "method", j.s("notifications/tools/list_changed") }, .{ "params", try j.obj(a, .{.{ "_meta", try j.obj(a, .{.{ j.sub_key, parsed.value }}) }}) } }));
        };
    }
    fn setTools(self: *Bridge, a: std.mem.Allocator, index: usize, bytes: []const u8) !void {
        const app = &self.apps[index];
        const parsed = try j.parse(a, bytes);
        const canonical = try catalog.encodeTools(a, parsed.value);
        if (std.mem.eql(u8, app.tools, canonical)) return;
        const copy = try g.dupe(u8, canonical);
        g.free(app.tools);
        app.tools = copy;
        try self.notify(a);
    }
    fn releaseLock(app: *App) void {
        if (app.lock_fd >= 0) {
            _ = c.close(app.lock_fd);
            app.lock_fd = -1;
        }
    }
    fn closePeer(self: *Bridge, peer: usize) !void {
        const p = &self.peers[peer];
        if (p.closing or p.fd < 0) return;
        p.closing = true;
        if (peer != 0) _ = c.shutdown(p.fd, c.SHUT_RDWR);
        for ([_]bool{ p.reading, p.writing, p.connecting }, 1..) |active, op| if (active) {
            _ = try self.ring.cancel(@intCast(cancel_tag + peer), @intCast(peer * 4 + op), 0);
            p.cancellations += 1;
        };
        self.reap(peer);
    }
    fn reap(self: *Bridge, peer: usize) void {
        const p = &self.peers[peer];
        if (!p.closing or p.reading or p.writing or p.connecting or p.cancellations != 0) return;
        if (p.fd >= 0 and peer != 0) _ = c.close(p.fd);
        p.input.deinit(g);
        for (p.output.items) |line| g.free(line);
        p.output.deinit(g);
        p.* = .{};
    }
    fn failApp(self: *Bridge, a: std.mem.Allocator, index: usize, message: []const u8) !void {
        const app = &self.apps[index];
        app.state = .offline;
        app.subscribed = false;
        app.list_id = 0;
        app.listen_id = 0;
        app.want_refresh = false;
        app.dirty = false;
        releaseLock(app);
        try self.closePeer(index + 1);
        for (&self.requests) |*slot| if (slot.*) |req| {
            if (req.app == index) {
                if (!self.eof) try self.rpcError(a, req.id(), -32000, message);
                req.doc.deinit();
                slot.* = null;
            }
        };
    }
    fn scan(self: *Bridge, a: std.mem.Allocator) !void {
        const entries = catalog.scan(a, self.filters, self.context) catch {
            self.catalog_error = true;
            for (&self.apps, 0..) |*app, index| if (app.present) {
                app.present = false;
                try self.failApp(a, index, "Discovery capacity exceeded");
            };
            return;
        };
        self.catalog_error = false;
        var found: [catalog.max_apps]bool = @splat(false);
        for (entries) |entry| {
            var target: ?usize = null;
            for (self.apps, 0..) |app, index| if (app.id) |id| {
                if (std.mem.eql(u8, id, entry.id)) {
                    target = index;
                    break;
                }
            };
            if (target == null) for (self.apps, 0..) |app, index| {
                if (app.id == null or (!app.present and self.peers[index + 1].fd < 0)) {
                    target = index;
                    break;
                }
            };
            const index = target orelse {
                self.catalog_error = true;
                continue;
            };
            found[index] = true;
            const app = &self.apps[index];
            if (app.id == null or !app.present or !std.mem.eql(u8, &app.key, &entry.key)) {
                if (app.present and app.id != null and std.mem.eql(u8, app.id.?, entry.id) and std.mem.eql(u8, app.endpoint, entry.endpoint)) {
                    // Catalog publication does not replace the connection or an
                    // in-flight mutation. Mark any old-key list read dirty.
                    g.free(app.baseline);
                    app.baseline = try g.dupe(u8, entry.tools);
                    app.key = entry.key;
                    try self.setTools(a, index, entry.tools);
                    app.dirty = true;
                    if (app.state == .ready) {
                        if (!app.want_refresh) app.deadline = fs.monotonic() + timeout_ms;
                        app.want_refresh = true;
                    }
                    continue;
                }
                if (app.id != null) {
                    try self.failApp(a, index, "Application descriptor changed");
                    g.free(app.id.?);
                    g.free(app.endpoint);
                    g.free(app.baseline);
                    g.free(app.tools);
                    g.free(app.epoch);
                    g.free(app.pages);
                    g.free(app.scope);
                }
                app.* = .{ .id = try g.dupe(u8, entry.id), .endpoint = try g.dupe(u8, entry.endpoint), .baseline = try g.dupe(u8, entry.tools), .tools = try g.dupe(u8, entry.tools), .key = entry.key, .present = true, .epoch = try g.dupe(u8, ""), .pages = try g.dupe(u8, "[]"), .scope = try g.dupe(u8, "private") };
                try self.notify(a);
            }
        }
        for (&self.apps, 0..) |*app, index| if (app.present and !found[index]) {
            app.present = false;
            try self.failApp(a, index, "Application removed");
            try self.notify(a);
        };
        self.next_scan = fs.monotonic() + 1000;
    }
    fn connect(self: *Bridge, a: std.mem.Allocator, index: usize) !void {
        const app = &self.apps[index];
        const p = &self.peers[index + 1];
        if (p.fd >= 0) return error.ConnectionClosing;
        const runtime = fs.env("XDG_RUNTIME_DIR") orelse return error.InvalidRuntimeDirectory;
        if (!std.fs.path.isAbsolute(runtime)) return error.InvalidRuntimeDirectory;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ runtime, app.endpoint });
        if (path.len >= p.address.path.len) return error.SocketPathTooLong;
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        p.fd = fd;
        p.address = .{ .path = @splat(0) };
        @memcpy(p.address.path[0..path.len], path);
        _ = try self.ring.connect(@intCast((index + 1) * 4 + 3), fd, @ptrCast(&p.address), @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1));
        p.connecting = true;
        app.state = .connecting;
        app.deadline = fs.monotonic() + timeout_ms;
    }
    fn useCache(self: *Bridge, a: std.mem.Allocator, index: usize) !bool {
        const bytes = self.cache.load(a, &self.apps[index].key) catch return false;
        try self.setTools(a, index, bytes);
        return true;
    }
    fn startRefresh(self: *Bridge, a: std.mem.Allocator, index: usize) !void {
        const app = &self.apps[index];
        if (app.state != .ready or app.list_id != 0 or !app.want_refresh) return;
        const lock = self.cache.lock(a, &app.key) catch |err| switch (err) {
            error.LockBusy => return,
            else => -1,
        };
        app.lock_fd = lock;
        if (try self.useCache(a, index)) {
            releaseLock(app);
            app.want_refresh = false;
            app.dirty = false;
            return;
        }
        g.free(app.epoch);
        app.epoch = try g.dupe(u8, self.cache.epoch(a, &app.key));
        g.free(app.pages);
        app.pages = try g.dupe(u8, "[]");
        app.page_count = 0;
        app.ttl = std.math.maxInt(i64);
        app.dirty = false;
        app.list_id = self.newId();
        app.deadline = fs.monotonic() + timeout_ms;
        try self.downstream(a, index, app.list_id, "tools/list", try j.obj(a, .{}));
    }
    fn aggregate(self: *Bridge, a: std.mem.Allocator) !j.V {
        if (self.catalog_error) return error.DiscoveryCapacity;
        var tools: std.array_list.Managed(j.V) = .init(a);
        // Sort by exposed names below, independent of reusable app slot order.
        var total: usize = 0;
        for (self.apps) |app| if (app.present) {
            const parsed = try j.parse(a, app.tools);
            for (parsed.value.array.items) |tool| {
                if (tools.items.len >= 1024) return error.CatalogCapacity;
                var value = tool;
                const name = j.str(j.get(tool, "name")).?;
                // put may resize the copied map, invalidating the original
                // map's storage layout. Read both original fields first.
                const description = j.str(j.get(tool, "description")) orelse "";
                try value.object.put(a, "name", j.s(try j.toolName(a, app.id.?, name)));
                try value.object.put(a, "description", j.s(try std.fmt.allocPrint(a, "[{s}/{s}] {s}", .{ app.id.?, name, description })));
                total += (try j.encode(a, value)).len + 1;
                if (total > j.limit - 4096) return error.CatalogCapacity;
                try tools.append(value);
            }
        };
        std.mem.sort(j.V, tools.items, {}, struct {
            fn less(_: void, x: j.V, y: j.V) bool {
                return std.mem.lessThan(u8, j.str(j.get(x, "name")).?, j.str(j.get(y, "name")).?);
            }
        }.less);
        return j.obj(a, .{ .{ "resultType", j.s("complete") }, .{ "tools", j.V{ .array = tools } }, .{ "ttlMs", j.n(0) }, .{ "cacheScope", j.s("private") } });
    }
    fn finishWaiting(self: *Bridge, a: std.mem.Allocator) !void {
        for (&self.requests) |*slot| if (slot.*) |*req| {
            if (req.downstream != 0) continue;
            if (req.app) |index| {
                const app = &self.apps[index];
                if (app.state != .ready or app.want_refresh or app.list_id != 0) continue;
                const parsed = try j.parse(a, app.tools);
                var exists = false;
                for (parsed.value.array.items) |tool| if (j.eq(j.get(tool, "name"), req.name)) {
                    exists = true;
                };
                if (!exists) {
                    try self.rpcError(a, req.id(), -32602, "Tool no longer exists");
                    req.doc.deinit();
                    slot.* = null;
                    continue;
                }
                const original = j.get(req.doc.value, "params");
                var params = try j.obj(a, .{});
                var iter = original.object.iterator();
                while (iter.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "_meta")) try params.object.put(a, field.key_ptr.*, field.value_ptr.*);
                try params.object.put(a, "name", j.s(req.name));
                req.downstream = self.newId();
                self.downstream(a, index, req.downstream, "tools/call", params) catch {
                    try self.failApp(a, index, "Application output capacity exceeded");
                };
            } else {
                var waiting = false;
                for (self.apps) |app| if (app.present and (app.want_refresh or app.list_id != 0)) {
                    waiting = true;
                };
                if (waiting) continue;
                const value = self.aggregate(a) catch {
                    try self.rpcError(a, req.id(), -32000, "Aggregate catalog capacity exceeded");
                    req.doc.deinit();
                    slot.* = null;
                    continue;
                };
                try self.result(a, req.id(), value);
                req.doc.deinit();
                slot.* = null;
            }
        };
    }
    fn upstream(self: *Bridge, a: std.mem.Allocator, bytes: []const u8) !void {
        const doc = j.parse(g, bytes) catch {
            try self.rpcError(a, .null, -32700, "Invalid JSON");
            return;
        };
        var owned = true;
        defer if (owned) doc.deinit();
        const v = doc.value;
        const id = j.get(v, "id");
        const method = j.str(j.get(v, "method")) orelse {
            try self.rpcError(a, .null, -32600, "Invalid request");
            return;
        };
        const params = j.get(v, "params");
        if (!j.eq(j.get(v, "jsonrpc"), "2.0")) {
            try self.rpcError(a, .null, -32600, "Invalid request");
            return;
        }
        if (id == .null) {
            if (std.mem.eql(u8, method, "notifications/cancelled")) {
                const target = j.get(params, "requestId");
                for (&self.requests) |*slot| if (slot.*) |req| {
                    if (try j.sameId(a, target, req.id())) {
                        if (req.app) |index| if (req.downstream != 0) self.cancel(a, index, req.downstream) catch {};
                        req.doc.deinit();
                        slot.* = null;
                    }
                };
                const token = try j.encode(a, target);
                for (&self.subscriptions) |*sub| if (sub.*) |active| if (std.mem.eql(u8, token, active)) {
                    g.free(active);
                    sub.* = null;
                };
            }
            return;
        }
        if (!j.validId(id) or (try j.encode(a, id)).len > 1024) {
            try self.rpcError(a, .null, -32600, "Invalid request ID");
            return;
        }
        for (self.requests) |slot| if (slot) |req| if (try j.sameId(a, id, req.id())) {
            try self.rpcError(a, id, -32600, "Duplicate request ID");
            return;
        };
        const token = try j.encode(a, id);
        for (self.subscriptions) |sub| if (sub) |active| if (std.mem.eql(u8, token, active)) {
            try self.rpcError(a, id, -32600, "Duplicate request ID");
            return;
        };
        if (std.mem.eql(u8, method, "initialize")) {
            try self.rpcError(a, id, -32601, "Only MCP 2026-07-28 is supported; initialize is not supported");
            return;
        }
        const meta = j.get(params, "_meta");
        const version = j.get(meta, j.version_key);
        if (version != .string or j.get(meta, j.caps_key) != .object) {
            try self.rpcError(a, id, -32602, "Required per-request MCP metadata missing");
            return;
        }
        if (!j.eq(version, j.version)) {
            try self.send(a, 0, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "id", id }, .{ "error", try j.obj(a, .{ .{ "code", j.n(-32022) }, .{ "message", j.s("Unsupported protocol version") }, .{ "data", try j.obj(a, .{ .{ "supported", try j.arr(a, &.{j.s(j.version)}) }, .{ "requested", version } }) } }) } }));
            return;
        }
        if (std.mem.eql(u8, method, "server/discover")) {
            try self.result(a, id, try j.obj(a, .{ .{ "resultType", j.s("complete") }, .{ "supportedVersions", try j.arr(a, &.{j.s(j.version)}) }, .{ "capabilities", try j.obj(a, .{.{ "tools", try j.obj(a, .{.{ "listChanged", j.V{ .bool = true } }}) }}) }, .{ "_meta", try j.obj(a, .{.{ "io.modelcontextprotocol/serverInfo", try j.obj(a, .{ .{ "name", j.s("ouro-mcp") }, .{ "version", j.s("0.1.0") } }) }}) }, .{ "ttlMs", j.n(0) }, .{ "cacheScope", j.s("private") } }));
            return;
        }
        if (std.mem.eql(u8, method, "subscriptions/listen")) {
            const notifications = j.get(params, "notifications");
            const wants = j.get(notifications, "toolsListChanged");
            if (wants != .bool or !wants.bool) {
                try self.rpcError(a, id, -32602, "Only toolsListChanged is supported");
                return;
            }
            for (&self.subscriptions) |*sub| if (sub.* == null) {
                sub.* = try g.dupe(u8, token);
                try self.send(a, 0, try j.obj(a, .{ .{ "jsonrpc", j.s("2.0") }, .{ "method", j.s("notifications/subscriptions/acknowledged") }, .{ "params", try j.obj(a, .{ .{ "_meta", try j.obj(a, .{.{ j.sub_key, id }}) }, .{ "notifications", try j.obj(a, .{.{ "toolsListChanged", j.V{ .bool = true } }}) } }) } }));
                return;
            };
            try self.rpcError(a, id, -32000, "Subscription capacity exceeded");
            return;
        }
        if (!std.mem.eql(u8, method, "tools/list") and !std.mem.eql(u8, method, "tools/call")) {
            try self.rpcError(a, id, -32601, "Method not found");
            return;
        }
        if (j.get(params, "cursor") != .null or j.get(params, "inputResponses") != .null or j.get(params, "requestState") != .null) {
            try self.rpcError(a, id, -32602, "Pagination cursors and multi-round-trip calls are not supported upstream");
            return;
        }
        try self.scan(a);
        var target: ?usize = null;
        var original_name: []const u8 = "";
        if (std.mem.eql(u8, method, "tools/call")) {
            const name = j.str(j.get(params, "name")) orelse {
                try self.rpcError(a, id, -32602, "Missing tool name");
                return;
            };
            for (self.apps, 0..) |app, index| if (app.present) {
                const parsed = try j.parse(a, app.tools);
                for (parsed.value.array.items) |tool| {
                    const original = j.str(j.get(tool, "name")).?;
                    if (std.mem.eql(u8, name, try j.toolName(a, app.id.?, original))) {
                        target = index;
                        original_name = original;
                        break;
                    }
                }
            };
            if (target == null) {
                try self.rpcError(a, id, -32602, "Unknown or removed tool");
                return;
            }
            var count: usize = 0;
            for (self.requests) |req| if (req != null and req.?.app == target) {
                count += 1;
            };
            if (count >= 30) {
                try self.rpcError(a, id, -32000, "Application request capacity exceeded");
                return;
            }
        }
        for (&self.requests) |*slot| if (slot.* == null) {
            const name_copy = try doc.arena.allocator().dupe(u8, original_name);
            slot.* = .{ .doc = doc, .app = target, .name = name_copy, .deadline = fs.monotonic() + timeout_ms };
            owned = false;
            if (target) |index| {
                const app = &self.apps[index];
                if (app.state == .offline) self.connect(a, index) catch {
                    try self.failApp(a, index, "Could not connect to application");
                } else if (app.state == .ready and !try self.useCache(a, index)) {
                    if (!app.want_refresh) app.deadline = fs.monotonic() + timeout_ms;
                    app.want_refresh = true;
                    try self.startRefresh(a, index);
                }
            } else {
                for (&self.apps, 0..) |*app, index| if (app.present) {
                    if (!try self.useCache(a, index)) {
                        if (app.state == .offline) {
                            try self.setTools(a, index, app.baseline);
                        } else if (app.state == .ready) {
                            if (!app.want_refresh) app.deadline = fs.monotonic() + timeout_ms;
                            app.want_refresh = true;
                            try self.startRefresh(a, index);
                        }
                    }
                };
            }
            try self.finishWaiting(a);
            return;
        };
        try self.rpcError(a, id, -32000, "Request capacity exceeded");
    }
    fn appMessage(self: *Bridge, a: std.mem.Allocator, index: usize, bytes: []const u8) !void {
        const parsed = try j.parse(a, bytes);
        const v = parsed.value;
        if (!j.eq(j.get(v, "jsonrpc"), "2.0")) return error.InvalidResponse;
        const app = &self.apps[index];
        const method = j.str(j.get(v, "method"));
        if (method) |m| {
            if (j.get(v, "id") != .null) return error.ServerRequestUnsupported;
            const p = j.get(v, "params");
            const sub = j.int(j.get(j.get(p, "_meta"), j.sub_key));
            if (std.mem.eql(u8, m, "notifications/subscriptions/acknowledged")) {
                if (app.state != .subscribing or sub != app.listen_id) return error.InvalidAcknowledgment;
                const filters = j.get(p, "notifications");
                if (filters != .object) return error.InvalidAcknowledgment;
                var iter = filters.object.iterator();
                while (iter.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "toolsListChanged") or field.value_ptr.* != .bool or !field.value_ptr.bool) return error.InvalidAcknowledgment;
                app.subscribed = j.get(filters, "toolsListChanged") == .bool;
                app.state = .ready;
                app.want_refresh = true;
                try self.startRefresh(a, index);
                try self.finishWaiting(a);
                return;
            }
            if (std.mem.eql(u8, m, "notifications/tools/list_changed")) {
                if (!app.subscribed or sub != app.listen_id) return error.UnacknowledgedNotification;
                try self.cache.invalidate(a, &app.key);
                app.dirty = true;
                app.want_refresh = true;
                if (app.list_id == 0) app.deadline = fs.monotonic() + timeout_ms;
                try self.startRefresh(a, index);
                return;
            }
            if (std.mem.eql(u8, m, "notifications/cancelled")) {
                if (j.int(j.get(p, "requestId")) != app.listen_id) return error.InvalidCancellation;
                app.subscribed = false;
                if (app.state == .subscribing) return error.SubscriptionClosed;
                return;
            }
            return error.UnrequestedNotification;
        }
        const id = j.int(j.get(v, "id")) orelse return error.InvalidResponse;
        const value = j.get(v, "result");
        const rpc_error = j.get(v, "error");
        if ((value == .null) == (rpc_error == .null)) return error.InvalidResponse;
        if (value != .null and (value != .object or (j.get(value, "resultType") != .null and !j.eq(j.get(value, "resultType"), "complete")))) return error.IncompleteResultUnsupported;
        if (id == app.listen_id) {
            if (app.state == .subscribing) {
                const code = j.int(j.get(rpc_error, "code"));
                if (code != -32601 and code != -32602) return error.SubscriptionFailed;
                app.state = .ready;
                app.want_refresh = true;
                app.subscribed = false;
                try self.startRefresh(a, index);
                try self.finishWaiting(a);
            } else {
                app.subscribed = false;
            }
            return;
        }
        if (id == app.list_id and id != 0) {
            if (rpc_error != .null) return error.ListFailed;
            const tools = j.get(value, "tools");
            try catalog.validateTools(tools);
            const previous = try j.parse(a, app.pages);
            var all = previous.value;
            try all.array.appendSlice(tools.array.items);
            try catalog.validateTools(all);
            const encoded = try j.encode(a, all);
            if (encoded.len > j.limit - 4096) return error.CatalogCapacity;
            g.free(app.pages);
            app.pages = try g.dupe(u8, encoded);
            // Each page's freshness starts when that page arrived, not when
            // the last page arrives. Store only the earliest remaining TTL.
            const page_ttl = @min(30 * 86400000, @max(0, j.int(j.get(value, "ttlMs")) orelse 0));
            app.ttl = @min(app.ttl, fs.now() + page_ttl);
            const scope = j.str(j.get(value, "cacheScope")) orelse "private";
            if (!std.mem.eql(u8, scope, "public") and !std.mem.eql(u8, scope, "private")) return error.InvalidCacheScope;
            if (app.page_count != 0 and !std.mem.eql(u8, scope, app.scope)) return error.InvalidCacheScope;
            g.free(app.scope);
            app.scope = try g.dupe(u8, scope);
            app.page_count += 1;
            const cursor = j.get(value, "nextCursor");
            if (cursor != .null) {
                if (cursor != .string or app.page_count >= 16) return error.PaginationCapacity;
                app.list_id = self.newId();
                try self.downstream(a, index, app.list_id, "tools/list", try j.obj(a, .{.{ "cursor", cursor }}));
                return;
            }
            app.list_id = 0;
            if (app.dirty or !std.mem.eql(u8, app.epoch, self.cache.epoch(a, &app.key))) {
                app.dirty = true;
                releaseLock(app);
                try self.startRefresh(a, index);
                return;
            }
            if (app.lock_fd >= 0) self.cache.store(a, &app.key, app.epoch, all, app.ttl - fs.now(), j.s(app.scope)) catch {};
            releaseLock(app);
            app.want_refresh = false;
            try self.setTools(a, index, app.pages);
            try self.finishWaiting(a);
            return;
        }
        for (&self.requests) |*slot| if (slot.*) |req| if (req.app == index and req.downstream == id) {
            var response = v;
            try response.object.put(a, "id", req.id());
            if (value != .null and j.get(value, "resultType") == .null) {
                var complete = value;
                try complete.object.put(a, "resultType", j.s("complete"));
                try response.object.put(a, "result", complete);
            }
            try self.send(a, 0, response);
            req.doc.deinit();
            slot.* = null;
            return;
        };
        // Late responses to cancelled requests are deliberately ignored.
    }
    fn consume(self: *Bridge, peer: usize, bytes: []const u8) !void {
        const p = &self.peers[peer];
        var start: usize = 0;
        for (bytes, 0..) |ch, end| if (ch == '\n') {
            var arena: std.heap.ArenaAllocator = .init(g);
            defer arena.deinit();
            const a = arena.allocator();
            if (p.input.items.len + end - start + 1 > j.limit) return error.MessageCapacity;
            try p.input.appendSlice(g, bytes[start..end]);
            if (peer == 0) try self.upstream(a, p.input.items) else try self.appMessage(a, peer - 1, p.input.items);
            if (p.closing or p.fd < 0) return;
            p.input.clearRetainingCapacity();
            p.frame_started = 0;
            start = end + 1;
        };
        if (p.input.items.len + bytes.len - start >= j.limit) return error.MessageCapacity;
        if (p.input.items.len == 0 and bytes.len > start) p.frame_started = fs.monotonic();
        try p.input.appendSlice(g, bytes[start..]);
    }
    fn shutdown(self: *Bridge, a: std.mem.Allocator) !void {
        if (self.eof) return;
        self.eof = true;
        self.exit_at = fs.monotonic() + 1000;
        for (&self.requests) |*slot| if (slot.*) |req| {
            if (req.app) |index| if (req.downstream != 0) self.cancel(a, index, req.downstream) catch {};
            req.doc.deinit();
            slot.* = null;
        };
        for (&self.apps, 0..) |*app, index| {
            if (app.list_id != 0) self.cancel(a, index, app.list_id) catch {};
            if (app.listen_id != 0 and (app.subscribed or app.state == .subscribing)) self.cancel(a, index, app.listen_id) catch {};
            releaseLock(app);
        }
        // Closing this process's streams ends subscriptions; do not enqueue an
        // unbounded batch of upstream completion responses during EOF cleanup.
    }
    fn maintenance(self: *Bridge, a: std.mem.Allocator) !void {
        const now = fs.monotonic();
        if (!self.eof) {
            if (now >= self.next_scan) try self.scan(a);
            for (&self.apps, 0..) |*app, index| {
                if (app.present and (app.want_refresh or app.state == .subscribing or app.state == .connecting)) {
                    if (now >= app.deadline) {
                        try self.failApp(a, index, "Application deadline exceeded");
                        continue;
                    }
                    try self.startRefresh(a, index);
                }
            }
            for (&self.requests) |*slot| if (slot.*) |req| if (now >= req.deadline) {
                if (req.app) |index| if (req.downstream != 0) self.cancel(a, index, req.downstream) catch {};
                try self.rpcError(a, req.id(), -32000, "Request deadline exceeded");
                req.doc.deinit();
                slot.* = null;
            };
            try self.finishWaiting(a);
        }
        for (self.peers, 0..) |p, peer| if (p.writing and now - p.write_started >= timeout_ms) {
            if (peer == 0) return error.SlowStdout;
            try self.failApp(a, peer - 1, "Application write deadline exceeded");
        };
        for (self.peers, 0..) |p, peer| if (p.input.items.len != 0 and now - p.frame_started >= timeout_ms) {
            if (peer == 0) return error.StdinFrameDeadline;
            try self.failApp(a, peer - 1, "Application frame deadline exceeded");
        };
    }
    fn run(self: *Bridge) !void {
        self.peers[0].fd = 0;
        try self.read(0);
        _ = try self.ring.timeout(timer_tag, &self.tick, 0, 0);
        while (true) {
            _ = try self.ring.submit();
            const event = try self.ring.copy_cqe();
            var arena: std.heap.ArenaAllocator = .init(g);
            defer arena.deinit();
            const a = arena.allocator();
            if (event.user_data == timer_tag) {
                try self.maintenance(a);
                if (self.eof) {
                    var output = false;
                    for (self.peers) |p| if (p.output.items.len != 0) {
                        output = true;
                    };
                    if (!output or fs.monotonic() >= self.exit_at) return;
                }
                _ = try self.ring.timeout(timer_tag, &self.tick, 0, 0);
                continue;
            }
            if (event.user_data >= cancel_tag) {
                const peer: usize = @intCast(event.user_data - cancel_tag);
                self.peers[peer].cancellations -= 1;
                self.reap(peer);
                continue;
            }
            const peer: usize = @intCast(event.user_data / 4);
            const op = event.user_data % 4;
            const p = &self.peers[peer];
            switch (op) {
                1 => p.reading = false,
                2 => p.writing = false,
                3 => p.connecting = false,
                else => unreachable,
            }
            if (p.closing) {
                self.reap(peer);
                continue;
            }
            if (event.res < 0 or (op != 3 and event.res == 0)) {
                if (peer == 0) {
                    if (op == 2) return error.StdoutClosed;
                    try self.shutdown(a);
                } else try self.failApp(a, peer - 1, "Application disconnected; call was not retried");
                continue;
            }
            switch (op) {
                1 => {
                    if (self.eof) continue;
                    self.consume(peer, p.read_buffer[0..@intCast(event.res)]) catch |err| {
                        if (peer == 0) return err;
                        try self.failApp(a, peer - 1, @errorName(err));
                    };
                    try self.read(peer);
                },
                2 => {
                    p.offset += @intCast(event.res);
                    if (p.offset == p.output.items[0].len) {
                        const line = p.output.orderedRemove(0);
                        p.output_bytes -= line.len;
                        g.free(line);
                        p.offset = 0;
                    }
                    try self.write(peer);
                },
                3 => {
                    if (self.eof) {
                        try self.closePeer(peer);
                        continue;
                    }
                    const index = peer - 1;
                    const app = &self.apps[index];
                    app.state = .subscribing;
                    app.listen_id = self.newId();
                    try self.downstream(a, index, app.listen_id, "subscriptions/listen", try j.obj(a, .{.{ "notifications", try j.obj(a, .{.{ "toolsListChanged", j.V{ .bool = true } }}) }}));
                    try self.read(peer);
                },
                else => unreachable,
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    var arena: std.heap.ArenaAllocator = .init(g);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var filters: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help")) {
            const help = "Usage: ouro-mcp [--app APPLICATION_ID]...\nStandalone MCP 2026-07-28 stdio bridge (Linux io_uring).\n";
            _ = c.write(1, help.ptr, help.len);
            return;
        }
        if (!std.mem.eql(u8, args[i], "--app") or i + 1 >= args.len or !catalog.validId(args[i + 1]) or filters.items.len >= catalog.max_apps) return error.InvalidArguments;
        i += 1;
        try filters.append(a, args[i]);
    }
    std.mem.sort([]const u8, filters.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    const context = try std.fmt.allocPrint(a, "uid={d};client=ouro-mcp/0.1.0;capabilities={{}};apps={s}", .{ c.getuid(), try std.mem.join(a, ",", filters.items) });
    const bridge = try g.create(Bridge);
    bridge.* = .{ .ring = try linux.IoUring.init(512, 0), .cache = Cache.init(a), .filters = filters.items, .context = context };
    // Ring teardown synchronously retires kernel references before process exit.
    defer bridge.ring.deinit();
    try bridge.scan(a);
    try bridge.run();
}

test {
    _ = j;
    _ = catalog;
}
