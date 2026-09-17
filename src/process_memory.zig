const std = @import("std");
const builtin = @import("builtin");

pub const Usage = struct {
    rss_bytes: u64,
    virtual_memory_bytes: u64,
    /// The memory this process owns, as the kernel charges it: private
    /// anonymous pages on Linux and the physical footprint on macOS. It leaves
    /// out the clean, file-backed pages of the executable and of the system
    /// libraries, which `rss_bytes` counts but no part of this process can
    /// free. On a small server that difference is most of the resident size.
    own_bytes: u64,
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
        // `resident_size` also counts the clean pages of the executable and of
        // every framework it maps, which is what makes a server of a few
        // megabytes look like it holds tens of them. The physical footprint is
        // the number Activity Monitor calls memory.
        .own_bytes = readMacosFootprint() orelse info.resident_size,
    };
}

/// The physical footprint of this process, or null when the kernel will not
/// report it. Only analyzed on macOS: `std.c` declares the Mach calls for
/// Darwin only, and `read` never reaches this file on another system.
fn readMacosFootprint() ?u64 {
    if (builtin.os.tag == .macos) {
        const task = std.c.mach_task_self();
        if (task == std.c.TASK.NULL) return null;

        var info_count = std.c.TASK.VM.INFO_COUNT;
        var info: std.c.task_vm_info_data_t = undefined;
        if (std.c.task_info(task, std.c.TASK.VM.INFO, @ptrCast(&info), &info_count) != 0) return null;
        return info.phys_footprint;
    }
    return null;
}

pub fn parseLinuxStatus(status: []const u8) Error!Usage {
    var rss_bytes: ?u64 = null;
    var virtual_memory_bytes: ?u64 = null;
    var rss_file_bytes: ?u64 = null;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            rss_bytes = try parseKibibytes(line["VmRSS:".len..]);
        } else if (std.mem.startsWith(u8, line, "VmSize:")) {
            virtual_memory_bytes = try parseKibibytes(line["VmSize:".len..]);
        } else if (std.mem.startsWith(u8, line, "RssFile:")) {
            rss_file_bytes = try parseKibibytes(line["RssFile:".len..]);
        }
    }

    const resident = rss_bytes orelse return error.MemoryStatisticsUnavailable;
    return .{
        .rss_bytes = resident,
        .virtual_memory_bytes = virtual_memory_bytes orelse return error.MemoryStatisticsUnavailable,
        // `RssFile` is the part of the resident size that comes from mapped
        // files, so what remains is the memory the process itself holds. It is
        // absent from kernels that do not report the breakdown, and the whole
        // resident size is then the best answer available.
        .own_bytes = resident -| (rss_file_bytes orelse 0),
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
    // Without the breakdown every resident byte counts as the process's own.
    try std.testing.expectEqual(45 * 1024, usage.own_bytes);
}

test "subtracts the file-backed part of the Linux resident size" {
    const usage = try parseLinuxStatus(
        "Name:\tszklana-pogoda\n" ++
            "VmSize:\t   123 kB\n" ++
            "VmRSS:\t4500 kB\n" ++
            "RssAnon:\t 600 kB\n" ++
            "RssFile:\t3900 kB\n" ++
            "RssShmem:\t    0 kB\n",
    );
    try std.testing.expectEqual(4500 * 1024, usage.rss_bytes);
    try std.testing.expectEqual(600 * 1024, usage.own_bytes);
}

test "rejects incomplete Linux process memory values" {
    try std.testing.expectError(error.MemoryStatisticsUnavailable, parseLinuxStatus("VmRSS:\t45 kB\n"));
}

test "rejects malformed Linux process memory values" {
    try std.testing.expectError(error.MemoryStatisticsUnavailable, parseLinuxStatus("VmRSS:\t45 bytes\nVmSize:\tabc kB\n"));
}

test "reads the memory of the running process" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const usage = try read();
    try std.testing.expect(usage.own_bytes > 0);
    try std.testing.expect(usage.virtual_memory_bytes > usage.own_bytes);
    // Only the Linux figure is a subtraction of one resident number from
    // another, so only there is it bounded by the resident size. The macOS
    // footprint counts compressed pages, which are by definition not resident.
    if (builtin.os.tag == .linux) try std.testing.expect(usage.rss_bytes >= usage.own_bytes);
}
