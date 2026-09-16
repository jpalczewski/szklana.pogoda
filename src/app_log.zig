const std = @import("std");

const max_message_bytes = 2048;
const max_line_bytes = 3 + 11 + 3 + 128 + 3 + (max_message_bytes * 6) + 3;
const max_access_line_bytes = 64 * 1024;

var write_mutex: std.Io.Mutex = .init;

/// Formats the common JSONL envelope. All string bytes are escaped as ASCII,
/// so the result is valid JSON even if a source string is not valid UTF-8.
pub fn formatLine(buffer: []u8, level: []const u8, scope: []const u8, message: []const u8) []const u8 {
    var index: usize = 0;
    append(buffer, &index, "{\"level\":\"");
    appendEscaped(buffer, &index, level);
    append(buffer, &index, "\",\"scope\":\"");
    appendEscaped(buffer, &index, scope);
    append(buffer, &index, "\",\"message\":\"");
    appendEscaped(buffer, &index, message);
    append(buffer, &index, "\"}\n");
    return buffer[0..index];
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var message_buffer: [max_message_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, format, args) catch "log message truncated";

    var scope_buffer: [128]u8 = undefined;
    const scope_name = std.fmt.bufPrint(&scope_buffer, "{t}", .{scope}) catch "unknown";

    var line_buffer: [max_line_bytes]u8 = undefined;
    const line = formatLine(&line_buffer, level.asText(), scope_name, message);

    write_mutex.lockUncancelable(std.Options.debug_io);
    defer write_mutex.unlock(std.Options.debug_io);
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, line) catch {};
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
    var index: usize = 0;
    append(buffer, &index, "{\"level\":\"info\",\"scope\":\"access\",\"message\":\"request completed\",\"client_ip\":");
    appendJsonString(buffer, &index, access.client_ip);
    append(buffer, &index, ",\"peer_ip\":");
    appendJsonString(buffer, &index, access.peer_ip);
    append(buffer, &index, ",\"method\":");
    appendJsonString(buffer, &index, access.method);
    append(buffer, &index, ",\"target\":");
    appendJsonString(buffer, &index, access.target);
    append(buffer, &index, ",\"status\":");
    appendNumber(buffer, &index, access.status);
    append(buffer, &index, ",\"duration_ms\":");
    appendNumber(buffer, &index, access.duration_ms);
    append(buffer, &index, ",\"user_agent\":");
    appendOptionalJsonString(buffer, &index, access.user_agent);
    append(buffer, &index, ",\"referer\":");
    appendOptionalJsonString(buffer, &index, access.referer);
    append(buffer, &index, ",\"response_bytes\":");
    appendNumber(buffer, &index, access.response_bytes);
    append(buffer, &index, "}\n");
    return buffer[0..index];
}

pub fn logAccess(access: Access) void {
    var line_buffer: [max_access_line_bytes]u8 = undefined;
    const line = formatAccessLine(&line_buffer, access);

    write_mutex.lockUncancelable(std.Options.debug_io);
    defer write_mutex.unlock(std.Options.debug_io);
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, line) catch {};
}

fn append(buffer: []u8, index: *usize, bytes: []const u8) void {
    std.debug.assert(index.* + bytes.len <= buffer.len);
    @memcpy(buffer[index.*..][0..bytes.len], bytes);
    index.* += bytes.len;
}

fn appendEscaped(buffer: []u8, index: *usize, bytes: []const u8) void {
    for (bytes) |byte| switch (byte) {
        '"' => append(buffer, index, "\\\""),
        '\\' => append(buffer, index, "\\\\"),
        '\x08' => append(buffer, index, "\\b"),
        '\x0c' => append(buffer, index, "\\f"),
        '\n' => append(buffer, index, "\\n"),
        '\r' => append(buffer, index, "\\r"),
        '\t' => append(buffer, index, "\\t"),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => append(buffer, index, &.{byte}),
        else => {
            const hex = "0123456789abcdef";
            append(buffer, index, "\\u00");
            append(buffer, index, &.{ hex[byte >> 4], hex[byte & 0x0f] });
        },
    };
}

fn appendJsonString(buffer: []u8, index: *usize, value: []const u8) void {
    append(buffer, index, "\"");
    appendEscaped(buffer, index, value);
    append(buffer, index, "\"");
}

fn appendOptionalJsonString(buffer: []u8, index: *usize, value: ?[]const u8) void {
    if (value) |string| return appendJsonString(buffer, index, string);
    append(buffer, index, "null");
}

fn appendNumber(buffer: []u8, index: *usize, value: anytype) void {
    var number_buffer: [32]u8 = undefined;
    const number = std.fmt.bufPrint(&number_buffer, "{d}", .{value}) catch unreachable;
    append(buffer, index, number);
}

test "JSONL formatter escapes JSON-sensitive bytes" {
    var buffer: [256]u8 = undefined;
    const line = formatLine(&buffer, "error", "default", "bad \"input\"\n\x01");
    try std.testing.expectEqualStrings(
        "{\"level\":\"error\",\"scope\":\"default\",\"message\":\"bad \\\"input\\\"\\n\\u0001\"}\n",
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
