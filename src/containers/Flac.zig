//! native flac container reader: id3v2 tags in front, streaminfo, seektable,
//! skipped metadata blocks, and one frame per packet; the codec verifies each
//! frame's checksums. frame boundaries are found by scanning for the next
//! valid frame header whose preceding crc-16 matches, so a frame must fit
//! options.bufferCapacity(). seeking jumps to the nearest seektable point, or
//! restarts at the first frame without one; frames are independent, so no
//! decoding history is needed.
const std = @import("std");
const types = @import("../types.zig");
const Source = @import("../Source.zig");
const PacketSource = @import("../PacketSource.zig");
const flac = @import("../codecs/flac.zig");
const Self = @This();

allocator: std.mem.Allocator,
source: Source,
metadata: types.Info,
/// fixed storage allocated by init; packets borrow it.
buffer: []u8,
start: usize = 0,
end: usize = 0,
eof: bool = false,
/// first sample number of the next packet.
frame: u64 = 0,
/// absolute offset of the first frame, which seektable offsets are relative to.
data_start: u64,
/// absolute offset and point count of the seektable; zero points when absent.
table_offset: u64 = 0,
table_points: u32 = 0,
/// samples per frame of fixed-blocksize streams, which number their frames.
fixed_block: u16,

const Frame = struct { len: usize, block_size: u32 };

/// a seektable point: the first sample of a frame and the frame's offset.
const Point = struct { sample: u64, offset: u64 };

const point_size = 18;

/// recognize the fLaC marker or an id3v2 tag in front of it; the dispatcher
/// already consumed these four bytes.
pub fn probe(prefix: []const u8) bool {
    return std.mem.eql(u8, prefix, "fLaC")
        or std.mem.startsWith(u8, prefix, "ID3");
}

/// skip any id3v2 tags, read streaminfo and skip all other metadata blocks,
/// leaving the source at the first frame. prefix holds the four bytes the
/// dispatcher consumed.
/// allocates source state and the frame buffer here.
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    prefix: [4]u8,
    options: types.Options,
) types.Error!PacketSource {
    const reader = source.reader;
    var marker = prefix;
    var position: u64 = marker.len;
    while (std.mem.startsWith(u8, &marker, "ID3")) {
        position += try skipTag(reader);
        try short(reader.readSliceAll(&marker));
        position += marker.len;
    }
    if (!std.mem.eql(u8, &marker, "fLaC")) return error.UnsupportedFormat;
    var streaminfo: [34]u8 = undefined;
    var first = true;
    var table_offset: u64 = 0;
    var table_points: u32 = 0;
    while (true) {
        var head: [4]u8 = undefined;
        try short(reader.readSliceAll(&head));
        position += head.len;
        const length = std.mem.readInt(u24, head[1..4], .big);
        if (first) {
            if (head[0] & 0x7F != 0 or length != streaminfo.len) {
                return error.InvalidData;
            }
            try short(reader.readSliceAll(&streaminfo));
            first = false;
        } else {
            if (head[0] & 0x7F == 127) return error.InvalidData;
            if (head[0] & 0x7F == 3) {
                if (table_offset != 0 or length % point_size != 0) {
                    return error.InvalidData;
                }
                table_offset = position;
                table_points = length / point_size;
            }
            try short(reader.discardAll(length));
        }
        position += length;
        if (head[0] & 0x80 != 0) break;
    }
    const min_block = std.mem.readInt(u16, streaminfo[0..2], .big);
    const max_block = std.mem.readInt(u16, streaminfo[2..4], .big);
    const fields = std.mem.readInt(u64, streaminfo[10..18], .big);
    const sample_rate: u32 = @intCast(fields >> 44);
    const channels: u16 = @intCast((fields >> 41 & 7) + 1);
    const bits: u8 = @intCast((fields >> 36 & 31) + 1);
    const total = fields & (1 << 36) - 1;
    if (min_block < flac.min_block or max_block < min_block) {
        return error.InvalidData;
    }
    if (options.bufferCapacity() < 32) return error.LimitExceeded;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const buffer = try allocator.alloc(u8, options.bufferCapacity());
    self.* = .{
        .allocator = allocator,
        .source = source,
        .buffer = buffer,
        .metadata = .{
            .format = .flac,
            .sample_rate = sample_rate,
            .channels = channels,
            .total_frames = if (total == 0) null else total,
        },
        .data_start = position,
        .table_offset = table_offset,
        .table_points = table_points,
        .fixed_block = max_block,
    };
    return .{
        .backend = .{ .flac = self },
        .encoding = .{ .flac = .{ .max_block = max_block, .bits = bits } },
        .format = .{ .sample_rate = sample_rate, .channels = channels },
        .seekable = source.seek_to != null,
        .max_payload_bytes = options.max_payload_bytes,
    };
}

/// skip the rest of an id3v2 tag whose first four bytes were read, including
/// a footer when the header announces one; return the bytes skipped.
fn skipTag(reader: *std.Io.Reader) types.Error!u64 {
    var header: [6]u8 = undefined;
    try short(reader.readSliceAll(&header));
    var size: u32 = 0;
    for (header[2..]) |byte| {
        if (byte & 0x80 != 0) return error.InvalidData;
        size = size << 7 | byte;
    }
    if (header[1] & 0x10 != 0) size += 10;
    try short(reader.discardAll(size));
    return header.len + size;
}

/// frames are delimited here, so only packet framing is meaningful.
pub fn configure(_: *Self, scheme: types.InputScheme) types.Error!void {
    if (scheme != .packets) return error.UnsupportedEncoding;
}

/// borrow the next complete frame until the next call; end follows the last
/// frame. input that does not end on a valid frame returns InvalidData.
pub fn next(self: *Self) types.Error!PacketSource.Event {
    while (true) {
        const data = self.buffer[self.start..self.end];
        if (data.len == 0 and self.eof) return .end;
        if (data.len != 0) {
            if (try self.frameAt(data)) |frame| {
                const timestamp = std.math.cast(i64, self.frame)
                    orelse return error.InvalidData;
                self.frame = std.math.add(u64, self.frame, frame.block_size)
                    catch return error.InvalidData;
                self.start += frame.len;
                return .{
                    .packet = .{
                        .bytes = data[0..frame.len],
                        .timestamp = .{
                            .value = timestamp,
                            .time_base = .{
                                .numerator = 1,
                                .denominator = self.metadata.sample_rate,
                            },
                        },
                        .duration = frame.block_size,
                    },
                };
            }
        }
        try self.refill();
    }
}

/// measure the frame starting data, or return null when more input is needed.
/// a frame ends where the next valid header follows its crc-16; the final
/// frame runs to the end of the input and the codec validates it.
fn frameAt(self: *const Self, data: []const u8) types.Error!?Frame {
    const header = flac.parseHeader(data)
        catch |err| switch (err) {
            error.TruncatedData => if (self.eof) return err else return null,
            error.InvalidData => return err,
        };
    // one running crc over the bytes before each candidate keeps this linear
    // in the buffer size however many false sync codes it holds.
    var crc: u16 = 0;
    var done: usize = 0;
    var at = header.len + 3;
    while (std.mem.findScalarPos(u8, data, at, 0xFF)) |sync| : (at = sync + 1) {
        _ = flac.parseHeader(data[sync..])
            catch |err| switch (err) {
                error.TruncatedData => if (self.eof) continue else return null,
                error.InvalidData => continue,
            };
        crc = flac.crc16(crc, data[done..sync - 2]);
        done = sync - 2;
        if (crc == std.mem.readInt(u16, data[done..][0..2], .big)) {
            return .{ .len = sync, .block_size = header.block_size };
        }
    }
    if (!self.eof) return null;
    return .{ .len = data.len, .block_size = header.block_size };
}

fn refill(self: *Self) types.Error!void {
    if (self.start != 0) {
        @memmove(
            self.buffer[0..self.end - self.start],
            self.buffer[self.start..self.end],
        );
        self.end -= self.start;
        self.start = 0;
    }
    if (self.end == self.buffer.len) return error.LimitExceeded;
    self.end += try self.source.reader.readSliceShort(self.buffer[self.end..]);
    if (self.end < self.buffer.len) self.eof = true;
}

/// total_frames is null when streaminfo does not record the sample count.
pub fn info(self: *const Self) types.Info {
    return self.metadata;
}

/// restart at the last seektable point at or before frame, or at the first
/// frame when none qualifies. the landing frame's own header must carry the
/// point's sample number, so a wrong table fails instead of misplacing audio.
pub fn seek(self: *Self, frame: u64) types.Error!PacketSource.SeekResult {
    const point = try self.pointBefore(frame);
    const offset = std.math.add(u64, self.data_start, point.offset)
        catch return error.InvalidData;
    self.source.seekTo(offset)
        catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            else => return err,
        };
    self.start = 0;
    self.end = 0;
    self.eof = false;
    if (point.sample != 0 or point.offset != 0) {
        const header = try self.peekHeader();
        const number = if (header.variable)
            header.number
        else
            std.math.mul(u64, header.number, self.fixed_block)
                catch return error.InvalidData;
        if (number != point.sample) return error.InvalidData;
    }
    self.frame = point.sample;
    const anchor = std.math.cast(i64, point.sample)
        orelse return error.InvalidData;
    return .{ .frame = anchor };
}

/// binary search the seektable in the source. placeholder points sort last
/// and are only reachable from the largest frame numbers, where the landing
/// check in seek rejects them.
fn pointBefore(self: *Self, frame: u64) types.Error!Point {
    var found: Point = .{ .sample = 0, .offset = 0 };
    var low: u32 = 0;
    var high = self.table_points;
    while (low < high) {
        const middle = low + (high - low) / 2;
        try self.source.seekTo(
            self.table_offset + @as(u64, middle) * point_size,
        );
        var bytes: [16]u8 = undefined;
        try short(self.source.reader.readSliceAll(&bytes));
        const point: Point = .{
            .sample = std.mem.readInt(u64, bytes[0..8], .big),
            .offset = std.mem.readInt(u64, bytes[8..16], .big),
        };
        if (point.sample <= frame) {
            found = point;
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return found;
}

/// parse the header of the buffered frame, reading more input as needed.
fn peekHeader(self: *Self) types.Error!flac.Header {
    while (true) {
        return flac.parseHeader(self.buffer[self.start..self.end])
            catch |err| switch (err) {
                error.InvalidData => err,
                error.TruncatedData => {
                    if (self.eof) return err;
                    try self.refill();
                    continue;
                },
            };
    }
}

/// release the frame buffer and state.
pub fn deinit(self: *Self) void {
    const allocator = self.allocator;
    allocator.free(self.buffer);
    allocator.destroy(self);
}

/// report input that ends early as TruncatedData.
fn short(
    result: anytype,
) types.Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result
        catch |err| switch (err) {
            error.EndOfStream => error.TruncatedData,
            else => |other| other,
        };
}

const testing = std.testing;
const Decoder = @import("../Decoder.zig");
const Md5 = std.crypto.hash.Md5;

/// ffmpeg-encoded: lpc, fixed predictors, mid/side, 24-bit mono, verbatim.
/// each carries the md5 of its decoded samples in streaminfo.
const fixtures = [_][]const u8{
    @embedFile("../testdata/stereo_lpc.flac"),
    @embedFile("../testdata/stereo_fixed.flac"),
    @embedFile("../testdata/stereo_mid_side.flac"),
    @embedFile("../testdata/mono_24bit.flac"),
    @embedFile("../testdata/noise_verbatim.flac"),
    @embedFile("../testdata/stereo_seektable.flac"),
};

/// fixtures keep streaminfo at byte 8: total samples, bit depth and the md5
/// of the decoded integers live there.
fn streamInfoFields(file: []const u8) u64 {
    return std.mem.readInt(u64, file[18..26], .big);
}

/// how a test reads a file: decoder options, frames per read, and whether the
/// source can seek.
const Read = struct {
    options: types.Options = .{},
    chunk: usize = 64,
    seekable: bool = true,
};

/// decode a whole file, hashing the reconstructed integers like streaminfo
/// does, and return the frame count.
fn decodeAll(
    allocator: std.mem.Allocator,
    file: []const u8,
    read: Read,
    digest: *[16]u8,
) !u64 {
    var reader = std.Io.Reader.fixed(file);
    const source = if (read.seekable)
        Source.fromFixed(&reader)
    else
        Source.fromReader(&reader);
    var decoder = try Decoder.initOptions(allocator, source, read.options);
    defer decoder.deinit();
    const channels = decoder.info().channels;
    const depth: u5 = @intCast(streamInfoFields(file) >> 36 & 31);
    const scale: f32 = @floatFromInt(@as(u32, 1) << depth);
    const out = try allocator.alloc(f32, read.chunk * channels);
    defer allocator.free(out);
    var md5 = Md5.init(.{});
    var frames: u64 = 0;
    while (true) {
        const count = try decoder.read(out);
        if (count == 0) break;
        frames += count;
        for (out[0..count * channels]) |sample| {
            const value: i32 = @intFromFloat(sample * scale);
            var word: [4]u8 = undefined;
            std.mem.writeInt(i32, &word, value, .little);
            md5.update(word[0..(@as(usize, depth) + 8) / 8]);
        }
    }
    md5.final(digest);
    try testing.expectEqual(frames, decoder.info().total_frames.?);
    return frames;
}

fn expectExact(
    allocator: std.mem.Allocator,
    file: []const u8,
    read: Read,
) !void {
    var digest: [16]u8 = undefined;
    const frames = try decodeAll(allocator, file, read, &digest);
    try testing.expectEqualSlices(u8, file[26..42], &digest);
    try testing.expectEqual(streamInfoFields(file) & (1 << 36) - 1, frames);
}

fn decodeBytes(file: []const u8, options: types.Options) !u64 {
    var digest: [16]u8 = undefined;
    return decodeAll(testing.allocator, file, .{ .options = options }, &digest);
}

test "fixtures decode to their STREAMINFO MD5 at any read size" {
    for (fixtures) |fixture| {
        for ([_]usize{ 1, 7, 4096 }) |chunk| {
            for ([_]usize{ 4096, 64 * 1024 }) |buffer| {
                for ([_]bool{ true, false }) |seekable| {
                    try expectExact(
                        testing.allocator,
                        fixture,
                        .{
                            .options = .{ .buffer_bytes = buffer },
                            .chunk = chunk,
                            .seekable = seekable,
                        },
                    );
                }
            }
        }
    }
}

test "stream information" {
    var reader = std.Io.Reader.fixed(fixtures[0]);
    const source = Source.fromFixed(&reader);
    var decoder = try Decoder.init(testing.allocator, source);
    defer decoder.deinit();
    const stream = decoder.info();
    try testing.expectEqual(types.Format.flac, stream.format);
    try testing.expectEqual(@as(u32, 44100), stream.sample_rate);
    try testing.expectEqual(@as(u16, 2), stream.channels);
    try testing.expectEqual(@as(?u64, 1764), stream.total_frames);
}

test "frames larger than the buffer are rejected" {
    const file = fixtures[0];
    const small = types.Options{ .buffer_bytes = 64 };
    try testing.expectError(error.LimitExceeded, decodeBytes(file, small));
    const tiny = types.Options{ .buffer_bytes = 16 };
    try testing.expectError(error.LimitExceeded, decodeBytes(file, tiny));
}

test "allocation failures are reported, not leaked" {
    for ([_]usize{ 0, 3 }) |which| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            expectExact,
            .{ fixtures[which], Read{ .chunk = 7 } },
        );
    }
}

test "decoding allocates nothing after init and deinit frees everything" {
    for (fixtures) |fixture| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var reader = std.Io.Reader.fixed(fixture);
        const source = Source.fromFixed(&reader);
        var decoder = try Decoder.init(failing.allocator(), source);
        const allocations = failing.allocations;
        const bytes = failing.allocated_bytes;
        var out: [8 * 100]f32 = undefined;
        const channels = decoder.info().channels;
        while (try decoder.read(out[0..100 * channels]) != 0) {}
        try testing.expectEqual(allocations, failing.allocations);
        try testing.expectEqual(bytes, failing.allocated_bytes);
        decoder.deinit();
        try testing.expectEqual(failing.allocations, failing.deallocations);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "every truncation is an error" {
    for ([_]usize{ 0, 3 }) |which| {
        const file = fixtures[which];
        for (0..file.len) |length| {
            if (decodeBytes(file[0..length], .{})) |_| {
                return error.TestUnexpectedResult;
            } else |_| {
            }
        }
    }
}

test "every single bit flip is survivable" {
    var copy: [4096]u8 = undefined;
    for ([_]usize{ 0, 3, 4 }) |which| {
        const file = fixtures[which];
        for (0..file.len) |index| {
            for (0..8) |bit| {
                @memcpy(copy[0..file.len], file);
                copy[index] ^= @as(u8, 1) << @intCast(bit);
                _ = decodeBytes(copy[0..file.len], .{}) catch {};
            }
        }
    }
}

test "a header-like byte pattern inside a frame is not a frame boundary" {
    var copy: [1024]u8 = undefined;
    const data = copy[0..fixtures[4].len];
    @memcpy(data, fixtures[4]);
    var start: usize = 4;
    while (true) {
        const last = data[start] & 0x80 != 0;
        start += 4 + std.mem.readInt(u24, data[start + 1..][0..3], .big);
        if (last) break;
    }
    const header = try flac.parseHeader(data[start..]);
    var end = start + header.len + 3;
    while (true) : (end += 1) {
        if (data[end] != 0xFF) continue;
        _ = flac.parseHeader(data[end..]) catch continue;
        const stored = std.mem.readInt(u16, data[end - 2..][0..2], .big);
        if (flac.crc16(0, data[start..end - 2]) == stored) break;
    }
    const inside = start + header.len + 20;
    @memcpy(data[inside..][0..header.len], data[start..][0..header.len]);
    std.mem.writeInt(
        u16,
        data[end - 2..][0..2],
        flac.crc16(0, data[start..end - 2]),
        .big,
    );
    try testing.expect(inside + header.len < end - 2);
    _ = try decodeBytes(data, .{});
}
test "malformed metadata" {
    const original = fixtures[0];
    var copy: [4096]u8 = undefined;
    const fields = streamInfoFields(original);
    const cases = [_]struct { anyerror, usize, u64 }{
        .{ error.InvalidData, 4, 1 },
        .{ error.InvalidData, 42, 127 },
        .{ error.InvalidData, 8, 0 },
        .{ error.InvalidData, 8, 255 },
        .{ error.UnsupportedEncoding, 0, fields | 31 << 36 },
        .{ error.InvalidData, 0, fields & ~(@as(u64, 31) << 36) },
        .{ error.InvalidData, 0, fields & ~(@as(u64, 0xFFFFF) << 44) },
        .{ error.TruncatedData, 0, fields + 1 },
        .{ error.InvalidData, 0, fields - 1 },
    };
    for (cases) |case| {
        @memcpy(copy[0..original.len], original);
        if (case[1] == 0) {
            std.mem.writeInt(u64, copy[18..26], case[2], .big);
        } else {
            copy[case[1]] = @intCast(case[2]);
            if (case[1] == 8) copy[9] = 0;
        }
        const result = decodeBytes(copy[0..original.len], .{});
        try testing.expectError(case[0], result);
    }
    try testing.expectError(
        error.TruncatedData,
        decodeBytes(original[0..20], .{}),
    );
}

fn decodeSamples(
    allocator: std.mem.Allocator,
    file: []const u8,
    seekable: bool,
) ![]f32 {
    var reader = std.Io.Reader.fixed(file);
    const source = if (seekable)
        Source.fromFixed(&reader)
    else
        Source.fromReader(&reader);
    var decoder = try Decoder.init(allocator, source);
    defer decoder.deinit();
    const channels = decoder.info().channels;
    const total: usize = @intCast(decoder.info().total_frames.?);
    const samples = try allocator.alloc(f32, total * channels);
    errdefer allocator.free(samples);
    var done: usize = 0;
    while (done < samples.len) {
        const got = try decoder.read(samples[done..]);
        if (got == 0) return error.TestUnexpectedResult;
        done += got * channels;
    }
    return samples;
}

fn expectSeek(decoder: *Decoder, samples: []const f32, frame: u64) !void {
    const channels = decoder.info().channels;
    try decoder.seekFrame(frame);
    try testing.expectEqual(frame, decoder.tellFrame());
    var out: [50 * 8]f32 = undefined;
    const rest = samples.len / channels - frame;
    const want = @min(rest, 50);
    var done: usize = 0;
    while (done < want) {
        const got = try decoder.read(out[0..(want - done) * channels]);
        try testing.expect(got != 0);
        const at = (frame + done) * channels;
        try testing.expectEqualSlices(
            f32,
            samples[at..][0..got * channels],
            out[0..got * channels],
        );
        done += got;
    }
}

test "seeking lands exactly on any frame, with or without a seek table" {
    for (fixtures) |file| {
        const samples = try decodeSamples(testing.allocator, file, true);
        defer testing.allocator.free(samples);
        var reader = std.Io.Reader.fixed(file);
        var decoder = try Decoder.init(
            testing.allocator,
            Source.fromFixed(&reader),
        );
        defer decoder.deinit();
        const total = decoder.info().total_frames.?;
        const stride: u64 = if (total > 5000) 61 else 1;
        var frame: u64 = total;
        // walk backwards and forwards so both seek directions are covered.
        while (true) : (frame -= stride) {
            try expectSeek(&decoder, samples, frame);
            if (frame < stride) break;
        }
        frame = 0;
        while (frame <= total) : (frame += stride) {
            try expectSeek(&decoder, samples, frame);
        }
        for (
            [_]u64{ 1152, 2303, 2304, 2305, 9215, 9216, 9217, total - 1 },
        ) |at| {
            if (at <= total) try expectSeek(&decoder, samples, at);
        }
        try testing.expectError(error.OutOfRange, decoder.seekFrame(total + 1));
    }
}

test "seeking uses the seek table instead of decoding from the start" {
    var file = fixtures[5][0..fixtures[5].len].*;
    const samples = try decodeSamples(testing.allocator, &file, true);
    defer testing.allocator.free(samples);
    // frames before the point at sample 9216 are destroyed.
    @memset(file[180 + 16..9668 + 180 - 16], 0);
    var reader = std.Io.Reader.fixed(&file);
    var decoder = try Decoder.init(
        testing.allocator,
        Source.fromFixed(&reader),
    );
    defer decoder.deinit();
    try expectSeek(&decoder, samples, 9300);
    try testing.expectError(error.InvalidData, decoder.seekFrame(100));
}

test "a seek table that disagrees with the frames is rejected" {
    const point_sample = 42 + 4 + 18 * 2;
    const point_offset = point_sample + 8;
    for (
        [_]usize{ point_sample + 7, point_offset + 7, point_offset + 1 },
    ) |where| {
        var file = fixtures[5][0..fixtures[5].len].*;
        file[where] +%= 1;
        var reader = std.Io.Reader.fixed(&file);
        var decoder = try Decoder.init(
            testing.allocator,
            Source.fromFixed(&reader),
        );
        defer decoder.deinit();
        try testing.expectError(error.InvalidData, decoder.seekFrame(6000));
    }
}

test "streaming input cannot seek" {
    var reader = std.Io.Reader.fixed(fixtures[5]);
    var decoder = try Decoder.init(
        testing.allocator,
        Source.fromReader(&reader),
    );
    defer decoder.deinit();
    try testing.expectError(error.Unseekable, decoder.seekFrame(0));
}

test "malformed seek tables are rejected" {
    const head = fixtures[5][0..42];
    const odd_length = [_]u8{ 0x83, 0, 0, 17 } ++ [_]u8{0} ** 17;
    const twice = [_]u8{ 0x03, 0, 0, 0, 0x83, 0, 0, 0 };
    const cases = [_][]const u8{ &odd_length, &twice };
    for (cases) |tail| {
        var file: [64]u8 = undefined;
        @memcpy(file[0..42], head);
        @memcpy(file[42..][0..tail.len], tail);
        var reader = std.Io.Reader.fixed(file[0..42 + tail.len]);
        try testing.expectError(
            error.InvalidData,
            Decoder.init(testing.allocator, Source.fromFixed(&reader)),
        );
    }
}

test "packets after a seek carry the landing timestamp" {
    var reader = std.Io.Reader.fixed(fixtures[5]);
    var packets = try PacketSource.init(
        testing.allocator,
        Source.fromFixed(&reader),
        .{},
    );
    defer packets.deinit();
    try packets.configure(.packets);
    try testing.expectError(
        error.InvalidData,
        packets.seek(std.math.maxInt(u64)),
    );
    for ([_][2]i64{ .{ 9300, 9216 }, .{ 9216, 9216 }, .{ 3, 0 } }) |pair| {
        const anchor = try packets.seek(@intCast(pair[0]));
        try testing.expectEqual(pair[1], anchor.frame);
        const event = try packets.next();
        try testing.expectEqual(pair[1], event.packet.timestamp.?.value);
    }
}

/// an id3v2.4 tag in front of a file; its payload is sync-like bytes that
/// must never be scanned.
const Tag = struct { size: u32, footer: bool = false };

fn withTags(
    allocator: std.mem.Allocator,
    tags: []const Tag,
    file: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (tags) |tag| {
        const flags: u8 = if (tag.footer) 0x10 else 0;
        try out.appendSlice(allocator, &.{ 'I', 'D', '3', 4, 0, flags });
        for ([_]u5{ 21, 14, 7, 0 }) |shift| {
            try out.append(allocator, @intCast(tag.size >> shift & 0x7F));
        }
        try out.appendNTimes(allocator, 0xFF, tag.size);
        if (tag.footer) try out.appendNTimes(allocator, 0, 10);
    }
    try out.appendSlice(allocator, file);
    return out.toOwnedSlice(allocator);
}

const tag_sets = [_][]const Tag{
    &.{},
    &.{.{ .size = 0 }},
    &.{.{ .size = 1000 }},
    &.{.{ .size = 100_000 }},
    &.{.{ .size = 7, .footer = true }},
    &.{ .{ .size = 5 }, .{ .size = 300, .footer = true } },
};

test "ID3v2 tags in front of a file change nothing" {
    for (fixtures) |file| {
        const plain = try decodeSamples(testing.allocator, file, true);
        defer testing.allocator.free(plain);
        for (tag_sets) |tags| {
            const tagged = try withTags(testing.allocator, tags, file);
            defer testing.allocator.free(tagged);
            for ([_]bool{ true, false }) |seekable| {
                const samples = try decodeSamples(
                    testing.allocator,
                    tagged,
                    seekable,
                );
                defer testing.allocator.free(samples);
                try testing.expectEqualSlices(f32, plain, samples);
            }
        }
    }
}

test "seeking works behind ID3v2 tags" {
    for ([_]usize{ 0, 5 }) |which| {
        const plain = try decodeSamples(
            testing.allocator,
            fixtures[which],
            true,
        );
        defer testing.allocator.free(plain);
        for (tag_sets[1..]) |tags| {
            const tagged = try withTags(
                testing.allocator,
                tags,
                fixtures[which],
            );
            defer testing.allocator.free(tagged);
            var reader = std.Io.Reader.fixed(tagged);
            var decoder = try Decoder.init(
                testing.allocator,
                Source.fromFixed(&reader),
            );
            defer decoder.deinit();
            const total = decoder.info().total_frames.?;
            for ([_]u64{ total, 9300, 2304, 1, total - 1, 0, 6000 }) |frame| {
                if (frame <= total) try expectSeek(&decoder, plain, frame);
            }
        }
    }
}

test "malformed or incomplete ID3v2 tags are rejected" {
    const cases = [_]struct { bytes: []const u8, err: anyerror }{
        .{
            .bytes = "ID3\x04\x00\x00\x00\x00\x00\x80",
            .err = error.InvalidData,
        },
        .{
            .bytes = "ID3\x04\x00\x00\x00\x00\x00\x64abc",
            .err = error.TruncatedData,
        },
        .{
            .bytes = "ID3\x04\x00\x00\x00\x00\x00\x00",
            .err = error.TruncatedData,
        },
        .{ .bytes = "ID3\x04\x00\x00\x00\x00\x00", .err = error.TruncatedData },
        .{
            .bytes = "ID3\x04\x00\x00\x00\x00\x00\x00RIFF",
            .err = error.UnsupportedFormat,
        },
    };
    for (cases) |case| {
        var reader = std.Io.Reader.fixed(case.bytes);
        try testing.expectError(
            case.err,
            Decoder.init(testing.allocator, Source.fromFixed(&reader)),
        );
    }
}

test "every truncation of a tagged file is an error" {
    const tagged = try withTags(
        testing.allocator,
        &.{.{ .size = 20 }},
        fixtures[0],
    );
    defer testing.allocator.free(tagged);
    for (0..tagged.len) |length| {
        if (decodeBytes(tagged[0..length], .{})) |_| {
            return error.TestUnexpectedResult;
        } else |_| {
        }
    }
}
