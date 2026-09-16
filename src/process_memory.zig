const std = @import("std");
const builtin = @import("builtin");

pub const Usage = struct {
    rss_bytes: u64,
    virtual_memory_bytes: u64,
};

pub const Error = error{MemoryStatisticsUnavailable};

pub fn read() Error!Usage {
    return switch (builtin.os.tag) {
        .linux => readLinux(),
        .macos => readMacos(),
        else => error.MemoryStatisticsUnavailable,
    };
}

fn readLinux() Error!Usage {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0) catch return error.MemoryStatisticsUnavailable;
    defer _ = std.posix.system.close(fd);

    var buffer: [4096]u8 = undefined;
    const bytes_read = std.posix.read(fd, &buffer) catch return error.MemoryStatisticsUnavailable;
    return parseLinuxStatus(buffer[0..bytes_read]);
}

fn readMacos() Error!Usage {
    var info: ProcTaskInfo = undefined;
    const bytes_read = proc_pidinfo(
        @intCast(std.posix.system.getpid()),
        proc_pidtaskinfo,
        0,
        @ptrCast(&info),
        @intCast(@sizeOf(ProcTaskInfo)),
    );
    if (bytes_read != @sizeOf(ProcTaskInfo)) return error.MemoryStatisticsUnavailable;

    return .{
        .rss_bytes = info.resident_size,
        .virtual_memory_bytes = info.virtual_size,
    };
}

pub fn parseLinuxStatus(status: []const u8) Error!Usage {
    var rss_bytes: ?u64 = null;
    var virtual_memory_bytes: ?u64 = null;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            rss_bytes = try parseKibibytes(line["VmRSS:".len..]);
        } else if (std.mem.startsWith(u8, line, "VmSize:")) {
            virtual_memory_bytes = try parseKibibytes(line["VmSize:".len..]);
        }
    }

    return .{
        .rss_bytes = rss_bytes orelse return error.MemoryStatisticsUnavailable,
        .virtual_memory_bytes = virtual_memory_bytes orelse return error.MemoryStatisticsUnavailable,
    };
}

fn parseKibibytes(value: []const u8) Error!u64 {
    var fields = std.mem.tokenizeAny(u8, value, " \t");
    const amount = fields.next() orelse return error.MemoryStatisticsUnavailable;
    const unit = fields.next() orelse return error.MemoryStatisticsUnavailable;
    if (!std.mem.eql(u8, unit, "kB") or fields.next() != null) return error.MemoryStatisticsUnavailable;
    const kibibytes = std.fmt.parseInt(u64, amount, 10) catch return error.MemoryStatisticsUnavailable;
    return std.math.mul(u64, kibibytes, 1024) catch error.MemoryStatisticsUnavailable;
}

const proc_pidtaskinfo = 4;

const ProcTaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    context_switches: i32,
    thread_count: i32,
    running_threads: i32,
    priority: i32,
};

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffer_size: c_int) c_int;

test "parses Linux process memory values in kibibytes" {
    const usage = try parseLinuxStatus(
        "Name:\tszklana-pogoda\n" ++
            "VmSize:\t   123 kB\n" ++
            "VmRSS:\t45 kB\n",
    );
    try std.testing.expectEqual(45 * 1024, usage.rss_bytes);
    try std.testing.expectEqual(123 * 1024, usage.virtual_memory_bytes);
}

test "rejects incomplete Linux process memory values" {
    try std.testing.expectError(error.MemoryStatisticsUnavailable, parseLinuxStatus("VmRSS:\t45 kB\n"));
}

test "rejects malformed Linux process memory values" {
    try std.testing.expectError(error.MemoryStatisticsUnavailable, parseLinuxStatus("VmRSS:\t45 bytes\nVmSize:\tabc kB\n"));
}
