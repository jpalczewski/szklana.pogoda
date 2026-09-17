const std = @import("std");

const max_message_bytes = 2048;
const max_scope_bytes = 128;
/// JSON escaping expands one input byte to at most six (`\u0000`), and a string
/// that is not valid UTF-8 is rendered as an array of at most four bytes per
/// input byte, so the envelope, the scope and a worst-case message fit here.
const max_line_bytes = 256 + (max_message_bytes + max_scope_bytes) * 6;
const max_access_line_bytes = 64 * 1024;

var write_mutex: std.Io.Mutex = .init;

/// Replaces a record that does not fit its buffer, so an oversized line is
/// reported instead of being written half-formed.
const truncated_line: Line = .{
    .level = "error",
    .scope = "app_log",
    .message = "log line truncated",
};

/// The envelope every application log line shares. `formatLine` encodes the
/// fields in declaration order and escapes non-ASCII text, so a line stays
/// ASCII and valid JSON whatever bytes the message carries.
pub const Line = struct {
    level: []const u8,
    scope: []const u8,
    message: []const u8,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var message_buffer: [max_message_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, format, args) catch "log message truncated";

    var scope_buffer: [max_scope_bytes]u8 = undefined;
    const scope_name = std.fmt.bufPrint(&scope_buffer, "{t}", .{scope}) catch "unknown";

    var line_buffer: [max_line_bytes]u8 = undefined;
    writeLine(formatLine(&line_buffer, Line{
        .level = level.asText(),
        .scope = scope_name,
        .message = message,
    }));
}

/// Encodes one record as a single JSONL line with the standard JSON encoder,
/// falling back to `truncated_line` when the buffer cannot hold the record.
pub fn formatLine(buffer: []u8, record: anytype) []const u8 {
    return encodeLine(buffer, record) orelse
        encodeLine(buffer, truncated_line) orelse
        buffer[0..0];
}

/// Serializes whole log lines, which concurrent connection threads may produce
/// at any moment.
fn writeLine(line: []const u8) void {
    if (line.len == 0) return;
    write_mutex.lockUncancelable(std.Options.debug_io);
    defer write_mutex.unlock(std.Options.debug_io);
    // zlinter-disable-next-line no_swallow_error - stdout is gone (e.g. a closed pipe); this logger has nowhere else to report it, and std.log routes back here, so logging the failure would recurse
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, line) catch {};
}

fn encodeLine(buffer: []u8, record: anytype) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var json: std.json.Stringify = .{
        .writer = &writer,
        // Escaping every non-ASCII character keeps log lines portable for
        // consumers that do not agree with the application about encoding.
        .options = .{ .escape_unicode = true },
    };
    json.write(record) catch return null;
    writer.writeByte('\n') catch return null;
    return writer.buffered();
}

pub const Access = struct {
    client_ip: []const u8,
    peer_ip: []const u8,
    method: []const u8,
    target: []const u8,
    status: u16,
    duration_ms: u64,
    user_agent: ?[]const u8,
    referer: ?[]const u8,
    response_bytes: usize,
};

/// Formats a completed HTTP request as a structured JSONL access log entry.
pub fn formatAccessLine(buffer: []u8, access: Access) []const u8 {
    return formatLine(buffer, .{
        .level = "info",
        .scope = "access",
        .message = "request completed",
        .client_ip = access.client_ip,
        .peer_ip = access.peer_ip,
        .method = access.method,
        .target = access.target,
        .status = access.status,
        .duration_ms = access.duration_ms,
        .user_agent = access.user_agent,
        .referer = access.referer,
        .response_bytes = access.response_bytes,
    });
}

pub fn logAccess(access: Access) void {
    var line_buffer: [max_access_line_bytes]u8 = undefined;
    writeLine(formatAccessLine(&line_buffer, access));
}

test "JSONL formatter escapes JSON-sensitive bytes" {
    var buffer: [256]u8 = undefined;
    const line = formatLine(&buffer, Line{ .level = "error", .scope = "default", .message = "bad \"input\"\n\x01" });
    try std.testing.expectEqualStrings(
        "{\"level\":\"error\",\"scope\":\"default\",\"message\":\"bad \\\"input\\\"\\n\\u0001\"}\n",
        line,
    );
}

test "JSONL formatter keeps non-ASCII messages ASCII" {
    var buffer: [256]u8 = undefined;
    const line = formatLine(&buffer, Line{ .level = "warn", .scope = "meteo", .message = "Zażółć" });
    try std.testing.expectEqualStrings(
        "{\"level\":\"warn\",\"scope\":\"meteo\",\"message\":\"Za\\u017c\\u00f3\\u0142\\u0107\"}\n",
        line,
    );
}

test "JSONL formatter emits valid JSON for a malformed message" {
    var buffer: [512]u8 = undefined;
    const line = formatLine(&buffer, Line{ .level = "warn", .scope = "meteo", .message = "bad \xff byte" });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(std.meta.Tag(std.json.Value).array, std.meta.activeTag(parsed.value.object.get("message").?));
    try std.testing.expectEqualStrings("warn", parsed.value.object.get("level").?.string);
}

test "JSONL formatter reports a record that does not fit" {
    var buffer: [96]u8 = undefined;
    const line = formatLine(&buffer, Line{ .level = "info", .scope = "meteo", .message = "x" ** 256 });
    try std.testing.expectEqualStrings(
        "{\"level\":\"error\",\"scope\":\"app_log\",\"message\":\"log line truncated\"}\n",
        line,
    );
}

test "access formatter records structured request metadata" {
    var buffer: [1024]u8 = undefined;
    const line = formatAccessLine(&buffer, .{
        .client_ip = "203.0.113.4",
        .peer_ip = "192.0.2.10",
        .method = "GET",
        .target = "/?q=\"hello\"",
        .status = 200,
        .duration_ms = 12,
        .user_agent = "browser\nagent",
        .referer = null,
        .response_bytes = 42,
    });
    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"scope\":\"access\",\"message\":\"request completed\",\"client_ip\":\"203.0.113.4\",\"peer_ip\":\"192.0.2.10\",\"method\":\"GET\",\"target\":\"/?q=\\\"hello\\\"\",\"status\":200,\"duration_ms\":12,\"user_agent\":\"browser\\nagent\",\"referer\":null,\"response_bytes\":42}\n",
        line,
    );
}
