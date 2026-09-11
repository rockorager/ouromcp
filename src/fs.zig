const std = @import("std");
const j = @import("json.zig");
pub const c = @cImport({
    // glibc's fortified variadic inline wrappers cannot be translated by Zig.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
});
pub fn env(key: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(key) orelse return null;
    const result = std.mem.span(value);
    return if (result.len != 0) result else null;
}
pub fn z(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    return a.dupeZ(u8, path);
}
pub fn readFd(a: std.mem.Allocator, fd: c_int) ![]u8 {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.InvalidFile;
    var data: std.Io.Writer.Allocating = .init(a);
    defer data.deinit();
    var buf: [8192]u8 = undefined;
    while (true) {
        const count = c.read(fd, &buf, buf.len);
        if (count < 0) return error.ReadFailed;
        if (count == 0) break;
        if (data.written().len + @as(usize, @intCast(count)) > j.limit) return error.Oversize;
        try data.writer.writeAll(buf[0..@intCast(count)]);
    }
    return data.toOwnedSlice();
}
pub fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = c.open(try z(a, path), c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    return readFd(a, fd);
}
pub fn secure(fd: c_int) bool {
    var st: c.struct_stat = undefined;
    return c.fstat(fd, &st) == 0 and st.st_uid == c.getuid() and st.st_mode & 0o022 == 0;
}
pub fn directory(a: std.mem.Allocator, root: []const u8, suffix: []const u8, create: bool) !c_int {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidPath;
    if (create) try mkdirs(a, root);
    var fd = c.open(try z(a, root), c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenFailed;
    errdefer _ = c.close(fd);
    if (!secure(fd)) return error.UnsafeDirectory;
    var parts = std.mem.splitScalar(u8, suffix, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const name = try z(a, part);
        if (create) _ = c.mkdirat(fd, name, 0o700);
        const next = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (next < 0) return error.OpenFailed;
        _ = c.close(fd);
        fd = next;
        if (!secure(fd)) return error.UnsafeDirectory;
    }
    return fd;
}
fn mkdirs(a: std.mem.Allocator, path: []const u8) !void {
    const copy = try z(a, path);
    for (copy, 0..) |ch, i| if (i != 0 and ch == '/') {
        copy[i] = 0;
        _ = c.mkdir(copy, 0o700);
        copy[i] = '/';
    };
    _ = c.mkdir(copy, 0o700);
}
pub fn readAt(a: std.mem.Allocator, dir: c_int, name: []const u8) ![]u8 {
    const fd = c.openat(dir, try z(a, name), c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (!secure(fd)) return error.UnsafeFile;
    return readFd(a, fd);
}
pub fn random() u64 {
    var value: u64 = 0;
    _ = std.os.linux.getrandom(std.mem.asBytes(&value).ptr, 8, 0);
    return value;
}
pub fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
pub fn monotonic() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
pub fn atomic(a: std.mem.Allocator, dir: c_int, name: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrintSentinel(a, ".tmp-{d}-{x}", .{ c.getpid(), random() }, 0);
    const fd = c.openat(dir, temp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    defer _ = c.unlinkat(dir, temp, 0);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
    if (c.renameat(dir, temp, dir, try z(a, name)) != 0) return error.RenameFailed;
}
