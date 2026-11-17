//! AMQP 0-9-1 primitive data types (spec §4.2.5, "AMQP Data Fields").

const std = @import("std");
const Io = std.Io;

pub const WriteError = Io.Writer.Error || error{ ShortStringTooLong, LongStringTooLong };

/// A fixed-point number equal to `value * 10^-scale`:
/// `{ .scale = 2, .value = 314 }` is 3.14.
pub const Decimal = struct {
    scale: u8,
    /// Signed, per RabbitMQ's errata; the spec's grammar says unsigned.
    value: i32,
};

/// Reads a short string: a u8 length followed by that many bytes.
///
/// Returns `error.EndOfStream` if the stream ends first, or if the string
/// does not fit in `r`'s buffer.
///
/// The data returned is invalidated by the next read from `r`.
pub fn readShortString(r: *Io.Reader) Io.Reader.Error![]const u8 {
    return readString(u8, r);
}

/// Same as `readShortString` except the length is a big-endian u32.
pub fn readLongString(r: *Io.Reader) Io.Reader.Error![]const u8 {
    return readString(u32, r);
}

/// Writes a short string: a u8 length followed by `s`.
///
/// Returns `error.ShortStringTooLong`, writing nothing, if `s` is longer than
/// 255 bytes.
pub fn writeShortString(w: *Io.Writer, s: []const u8) WriteError!void {
    return writeString(u8, error.ShortStringTooLong, w, s);
}

/// Same as `writeShortString` except the length is a big-endian u32 and the
/// error is `error.LongStringTooLong`.
pub fn writeLongString(w: *Io.Writer, s: []const u8) WriteError!void {
    return writeString(u32, error.LongStringTooLong, w, s);
}

fn readString(comptime Len: type, r: *Io.Reader) Io.Reader.Error![]const u8 {
    const len = try r.takeInt(Len, .big);
    // `take` asserts that `len` fits in the buffer, and `len` comes from the peer.
    if (len > r.buffer.len) return error.EndOfStream;
    return r.take(len);
}

fn writeString(
    comptime Len: type,
    comptime too_long: WriteError,
    w: *Io.Writer,
    s: []const u8,
) WriteError!void {
    if (s.len > std.math.maxInt(Len)) return too_long;
    try w.writeInt(Len, @intCast(s.len), .big);
    try w.writeAll(s);
}

/// Reads a `Decimal`: a scale byte followed by a big-endian i32 value.
pub fn readDecimal(r: *Io.Reader) Io.Reader.Error!Decimal {
    const scale = try r.takeByte();
    const value = try r.takeInt(i32, .big);
    return .{ .scale = scale, .value = value };
}

/// Writes a `Decimal`: a scale byte followed by a big-endian i32 value.
pub fn writeDecimal(w: *Io.Writer, d: Decimal) Io.Writer.Error!void {
    try w.writeByte(d.scale);
    try w.writeInt(i32, d.value, .big);
}

const testing = std.testing;

test "short string round-trips" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeShortString(&w, "guest");
    try testing.expectEqualSlices(u8, "\x05guest", w.buffered());

    var r: Io.Reader = .fixed(w.buffered());
    try testing.expectEqualStrings("guest", try readShortString(&r));
    try testing.expectEqual(0, r.bufferedLen());
}

test "every length from 0 to 255 round-trips" {
    var source: [255]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @intCast(i);
    var buf: [256]u8 = undefined;
    for (0..source.len + 1) |len| {
        var w: Io.Writer = .fixed(&buf);
        try writeShortString(&w, source[0..len]);
        try testing.expectEqual(len + 1, w.buffered().len);
        try testing.expectEqual(len, w.buffered()[0]);

        var r: Io.Reader = .fixed(w.buffered());
        try testing.expectEqualSlices(u8, source[0..len], try readShortString(&r));
        try testing.expectEqual(0, r.bufferedLen());
    }
}

test "short string longer than 255 bytes is rejected" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const too_long: [256]u8 = @splat('a');
    try testing.expectError(error.ShortStringTooLong, writeShortString(&w, &too_long));
    try testing.expectEqual(0, w.buffered().len);
}

test "long string round-trips with a big-endian u32 length" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeLongString(&w, "\x00PLAIN\x00");
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x07\x00PLAIN\x00", w.buffered());

    var r: Io.Reader = .fixed(w.buffered());
    try testing.expectEqualStrings("\x00PLAIN\x00", try readLongString(&r));
}

test "truncated strings fail with EndOfStream" {
    var short: Io.Reader = .fixed("\x05gue");
    try testing.expectError(error.EndOfStream, readShortString(&short));
    var long: Io.Reader = .fixed("\xff\xff\xff\xffabc");
    try testing.expectError(error.EndOfStream, readLongString(&long));
    var empty: Io.Reader = .fixed("");
    try testing.expectError(error.EndOfStream, readShortString(&empty));
}

test "decimal round-trips" {
    var buf: [5]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDecimal(&w, .{ .scale = 2, .value = 12345 });
    try testing.expectEqualSlices(u8, "\x02\x00\x00\x30\x39", w.buffered());
    var r: Io.Reader = .fixed(w.buffered());
    try testing.expectEqual(Decimal{ .scale = 2, .value = 12345 }, try readDecimal(&r));
}

test "decimal value is signed" {
    var buf: [5]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDecimal(&w, .{ .scale = 2, .value = -1 });
    try testing.expectEqualSlices(u8, "\x02\xff\xff\xff\xff", w.buffered());
    var r: Io.Reader = .fixed(w.buffered());
    try testing.expectEqual(Decimal{ .scale = 2, .value = -1 }, try readDecimal(&r));
}

test "strings larger than the reader buffer return EndOfStream" {
    var buf: [8]u8 = undefined;
    var fits: testing.Reader = .init(&buf, &.{.{ .buffer = "\x00\x00\x00\x0801234567" }});
    try testing.expectEqualStrings("01234567", try readLongString(&fits.interface));
    var long: testing.Reader = .init(&buf, &.{.{ .buffer = "\x00\x00\x00\x090123456789" }});
    try testing.expectError(error.EndOfStream, readLongString(&long.interface));
    var short: testing.Reader = .init(&buf, &.{.{ .buffer = "\x09012345678" }});
    try testing.expectError(error.EndOfStream, readShortString(&short.interface));
}
