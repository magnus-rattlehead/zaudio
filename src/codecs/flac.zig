//! native flac frame decoder (rfc 9639): one complete frame per packet.
//! supports 1-8 channels at 4-24 bits per sample, so every sample converts to
//! f32 exactly. frames carry no inter-frame state.
const std = @import("std");
const types = @import("../types.zig");
const Codec = @import("../Codec.zig");
const Crc8 = std.hash.crc.Crc8Smbus;
const Self = @This();

pub const Error = types.Error;
pub const Config = types.FlacConfig;
/// flac frames are independent, so a seek needs no earlier frames.
pub const preroll_frames: u64 = 0;

allocator: std.mem.Allocator,
config: types.FlacConfig,
format: types.AudioFormat,
/// one i32 plane of config.max_block samples per channel.
planes: []i32,
/// exact power of two mapping integers to [-1, 1).
scale: f32,

const max_channels = 8;
const min_bits = 4;
const max_bits = 24;
pub const min_block = 16;
const max_block = 65535;

/// parsed frame header; sample_rate and bits are null when streaminfo supplies
/// them.
pub const Header = struct {
    variable: bool,
    /// frame number for fixed block size, first sample number for variable.
    number: u64,
    block_size: u32,
    sample_rate: ?u32,
    bits: ?u8,
    assignment: u4,
    /// header length in bytes, including its crc-8.
    len: usize,

    pub fn channels(self: Header) u16 {
        return if (self.assignment < 8) @as(u16, self.assignment) + 1 else 2;
    }
};

const HeaderError = error{ InvalidData, TruncatedData };

/// slicing-by-8 tables for crc-16 with polynomial 0x8005: tables[k][b] is the
/// crc of byte b followed by k zero bytes.
const crc16_tables = blk: {
    @setEvalBranchQuota(100_000);
    var tables: [8][256]u16 = undefined;
    for (&tables[0], 0..) |*entry, byte| {
        var crc: u16 = @as(u16, byte) << 8;
        for (0..8) |_| {
            crc = (crc << 1) ^ (if (crc & 0x8000 != 0) @as(u16, 0x8005) else 0);
        }
        entry.* = crc;
    }
    for (1..8) |slice| {
        for (0..256) |byte| {
            const previous = tables[slice - 1][byte];
            tables[slice][byte] = (previous << 8) ^ tables[0][previous >> 8];
        }
    }
    break :blk tables;
};

/// continue a crc-16 (polynomial 0x8005, initial value 0, no reflection) over
/// bytes, eight at a time. start with state 0.
pub fn crc16(state: u16, bytes: []const u8) u16 {
    const t = &crc16_tables;
    var crc = state;
    var rest = bytes;
    while (rest.len >= 8) : (rest = rest[8..]) {
        crc = t[7][@as(u8, @truncate(crc >> 8)) ^ rest[0]]
            ^ t[6][@as(u8, @truncate(crc)) ^ rest[1]]
            ^ t[5][rest[2]]
            ^ t[4][rest[3]]
            ^ t[3][rest[4]]
            ^ t[2][rest[5]]
            ^ t[1][rest[6]]
            ^ t[0][rest[7]];
    }
    for (rest) |byte| {
        crc = (crc << 8) ^ t[0][@as(u8, @truncate(crc >> 8)) ^ byte];
    }
    return crc;
}

const rates = [_]u32{
    88200,
    176400,
    192000,
    8000,
    16000,
    22050,
    24000,
    32000,
    44100,
    48000,
    96000,
};

/// parse and validate a frame header at the start of bytes. TruncatedData
/// means more input is needed; InvalidData means this is not a header.
pub fn parseHeader(bytes: []const u8) HeaderError!Header {
    if (bytes.len >= 2 and (bytes[0] != 0xFF or bytes[1] & 0xFE != 0xF8)) {
        return error.InvalidData;
    }
    if (bytes.len < 6) return error.TruncatedData;
    const variable = bytes[1] & 1 != 0;
    const size_code: u4 = @intCast(bytes[2] >> 4);
    const rate_code: u4 = @intCast(bytes[2] & 15);
    const assignment: u4 = @intCast(bytes[3] >> 4);
    const bits_code: u3 = @intCast((bytes[3] >> 1) & 7);
    if (bytes[3] & 1 != 0 or assignment > 10) return error.InvalidData;
    var pos: usize = 4;
    const number = try codedNumber(bytes, &pos, variable);
    const block_size: u32 = switch (size_code) {
        0 => return error.InvalidData,
        1 => 192,
        2...5 => @as(u32, 576) << @intCast(size_code - 2),
        6 => @as(u32, try takeInt(u8, bytes, &pos)) + 1,
        7 => @as(u32, try takeInt(u16, bytes, &pos)) + 1,
        8...15 => @as(u32, 256) << @intCast(size_code - 8),
    };
    if (block_size > max_block) return error.InvalidData;
    const sample_rate: ?u32 = switch (rate_code) {
        0 => null,
        1...11 => rates[rate_code - 1],
        12 => @as(u32, try takeInt(u8, bytes, &pos)) * 1000,
        13 => try takeInt(u16, bytes, &pos),
        14 => @as(u32, try takeInt(u16, bytes, &pos)) * 10,
        15 => return error.InvalidData,
    };
    if (sample_rate == 0) return error.InvalidData;
    const bits: ?u8 = switch (bits_code) {
        0 => null,
        1 => 8,
        2 => 12,
        3 => return error.InvalidData,
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
    };
    if (pos >= bytes.len) return error.TruncatedData;
    if (bytes[pos] != Crc8.hash(bytes[0..pos])) return error.InvalidData;
    return .{
        .variable = variable,
        .number = number,
        .block_size = block_size,
        .sample_rate = sample_rate,
        .bits = bits,
        .assignment = assignment,
        .len = pos + 1,
    };
}

fn takeInt(
    comptime T: type,
    bytes: []const u8,
    pos: *usize,
) error{ TruncatedData }!T {
    const size = @sizeOf(T);
    if (pos.* + size > bytes.len) return error.TruncatedData;
    defer pos.* += size;
    return std.mem.readInt(T, bytes[pos.*..][0..size], .big);
}

/// utf-8 style number of up to 6 bytes (fixed) or 7 bytes (variable).
fn codedNumber(bytes: []const u8, pos: *usize, variable: bool) HeaderError!u64 {
    const first = bytes[pos.*];
    const ones = @clz(~first);
    if (ones == 1 or ones > (if (variable) @as(u4, 7) else 6)) {
        return error.InvalidData;
    }
    const len: usize = if (ones == 0) 1 else ones;
    if (pos.* + len > bytes.len) return error.TruncatedData;
    var value: u64 = if (len == 1)
        first
    else
        first & (@as(u8, 0x7F) >> @intCast(len));
    for (bytes[pos.* + 1..][0..len - 1]) |byte| {
        if (byte & 0xC0 != 0x80) return error.InvalidData;
        value = value << 6 | (byte & 0x3F);
    }
    pos.* += len;
    return value;
}

/// validate configuration and allocate the sample planes. UnitAdapter
/// allocates max_block * channels f32 samples of output.
pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    format: types.AudioFormat,
    options: types.Options,
) Error!Codec {
    if (
        format.channels > max_channels
            or config.max_block < min_block
            or config.bits < min_bits
    ) {
        return error.InvalidData;
    }
    if (config.bits > max_bits) return error.UnsupportedEncoding;
    const planes = try allocator.alloc(
        i32,
        @as(usize, format.channels) * config.max_block,
    );
    errdefer allocator.free(planes);
    const unit = Self{
        .allocator = allocator,
        .config = config,
        .format = format,
        .planes = planes,
        .scale = std.math.ldexp(@as(f32, 1), -@as(i32, config.bits - 1)),
    };
    const adapter = try Codec.UnitAdapter(Self)
        .init(allocator, unit, .packets, config.max_block, format, options);
    return adapter.interface(.flac);
}

/// flac frames are independent, so there is no history to clear.
pub fn reset(_: *Self) void {}

/// release the sample planes; UnitAdapter releases its pcm output.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.planes);
}

/// decode exactly one frame (header through crc-16) into interleaved f32.
/// out must hold config.max_block * channels samples; returns frames written.
pub fn decodeUnit(
    self: *Self,
    bytes: []const u8,
    out: []f32,
) types.Error!usize {
    const header = try parseHeader(bytes);
    const channels: usize = self.format.channels;
    const rate = header.sample_rate orelse self.format.sample_rate;
    const depth = header.bits orelse self.config.bits;
    if (
        header.channels() != channels
            or depth != self.config.bits
            or rate != self.format.sample_rate
    ) {
        return error.UnsupportedEncoding;
    }
    const block: usize = header.block_size;
    if (block > self.config.max_block) return error.LimitExceeded;
    if (out.len < block * channels) return error.InvalidBufferSize;
    if (bytes.len < header.len + 2) return error.TruncatedData;
    const body = bytes[0..bytes.len - 2];
    const stored = std.mem.readInt(u16, bytes[body.len..][0..2], .big);
    if (stored != crc16(0, body)) return error.InvalidData;
    var bits = Bits{ .bytes = body, .pos = header.len * 8 };
    for (0..channels) |channel| {
        const samples = self.plane(channel, block);
        try subframe(&bits, samples, self.width(header.assignment, channel));
    }
    bits.pos = std.mem.alignForward(usize, bits.pos, 8);
    if (bits.pos != body.len * 8) return error.InvalidData;
    if (header.assignment >= 8) {
        decorrelate(
            header.assignment,
            self.plane(0, block),
            self.plane(1, block),
        );
    }
    for (0..channels) |channel| {
        const samples = self.plane(channel, block);
        for (samples, 0..) |sample, index| {
            out[index * channels + channel] = @as(f32, @floatFromInt(sample))
                * self.scale;
        }
    }
    return block;
}

fn plane(self: *const Self, channel: usize, block: usize) []i32 {
    return self.planes[channel * self.config.max_block..][0..block];
}

/// subframe bit depth; the side channel needs one extra bit.
fn width(self: *const Self, assignment: u4, channel: usize) u8 {
    const side = switch (assignment) {
        8, 10 => channel == 1,
        9 => channel == 0,
        else => false,
    };
    return self.config.bits + @intFromBool(side);
}

fn decorrelate(assignment: u4, first: []i32, second: []i32) void {
    for (first, second) |*a, *b| {
        switch (assignment) {
            8 => b.* = a.* - b.*,
            9 => a.* += b.*,
            else => {
                const mid = (a.* << 1) | (b.* & 1);
                a.* = (mid + b.*) >> 1;
                b.* = (mid - b.*) >> 1;
            },
        }
    }
}

const fixed_coefficients = [5][4]i32{
    .{ 0, 0, 0, 0 },
    .{ 1, 0, 0, 0 },
    .{ 2, -1, 0, 0 },
    .{ 3, -3, 1, 0 },
    .{ 4, -6, 4, -1 },
};

fn subframe(b: *Bits, out: []i32, depth: u8) error{ InvalidData }!void {
    if (try b.read(1) != 0) return error.InvalidData;
    const kind = try b.read(6);
    var wasted: u8 = 0;
    if (try b.read(1) == 1) {
        wasted = std.math.cast(u8, try b.unary() + 1)
            orelse return error.InvalidData;
        if (wasted >= depth) return error.InvalidData;
    }
    const bits = depth - wasted;
    switch (kind) {
        0 => @memset(out, try b.readSigned(bits)),
        1 => for (out) |*sample| {
            sample.* = try b.readSigned(bits);
        },
        8...12 => {
            const order = kind - 8;
            try warmup(b, out, order, bits);
            try residual(b, out, order);
            try restore(out, fixed_coefficients[order][0..order], 0, bits);
        },
        32...63 => {
            const order = kind - 31;
            try warmup(b, out, order, bits);
            const precision = try b.read(4) + 1;
            if (precision == 16) return error.InvalidData;
            const shift = try b.readSigned(5);
            if (shift < 0) return error.InvalidData;
            var coefficients: [32]i32 = undefined;
            for (coefficients[0..order]) |*coefficient| {
                coefficient.* = try b.readSigned(precision);
            }
            try residual(b, out, order);
            try restore(out, coefficients[0..order], @intCast(shift), bits);
        },
        else => return error.InvalidData,
    }
    if (wasted != 0) {
        for (out) |*sample| sample.* <<= @intCast(wasted);
    }
}

fn warmup(
    b: *Bits,
    out: []i32,
    order: usize,
    bits: u8,
) error{ InvalidData }!void {
    if (order > out.len) return error.InvalidData;
    for (out[0..order]) |*sample| sample.* = try b.readSigned(bits);
}

/// partitioned Rice residuals for out[order..]; the order warm-up samples
/// are already in place.
fn residual(b: *Bits, out: []i32, order: usize) error{ InvalidData }!void {
    const method = try b.read(2);
    if (method > 1) return error.InvalidData;
    const parameter_bits: u32 = if (method == 0) 4 else 5;
    const escape = (@as(u32, 1) << @intCast(parameter_bits)) - 1;
    const partition_order: u5 = @intCast(try b.read(4));
    const partitions = @as(usize, 1) << partition_order;
    if (out.len & (partitions - 1) != 0) return error.InvalidData;
    const size = out.len >> partition_order;
    if (size < order) return error.InvalidData;
    var start = order;
    for (1..partitions + 1) |index| {
        const samples = out[start..index * size];
        start = index * size;
        const parameter = try b.read(parameter_bits);
        if (parameter == escape) {
            const raw = try b.read(5);
            for (samples) |*sample| {
                sample.* = if (raw == 0) 0 else try b.readSigned(raw);
            }
        } else {
            try b.riceBlock(samples, parameter);
        }
    }
}

/// add the prediction to each residual in place, rejecting samples outside the
/// subframe bit depth. each restored sample depends on the previous one, so the
/// speed comes from avoiding memory round trips: orders up to 12 are unrolled
/// at compile time with the last samples held in registers, and higher orders
/// keep only the newest eight there and read the rest with widening vector
/// multiplies.
fn restore(
    out: []i32,
    coefficients: []const i32,
    shift: u6,
    bits: u8,
) error{ InvalidData }!void {
    const outside = switch (coefficients.len) {
        inline 0...12 => |order| Unrolled(order)
                .restore(out, coefficients, shift, bits),
        else => restoreWide(out, coefficients, shift, bits),
    };
    if (outside != 0) return error.InvalidData;
}

/// unrolled restore for one order. it returns nonzero when a restored sample
/// falls outside bits; stored values are truncated, so out-of-range input
/// cannot trap.
fn Unrolled(comptime order: usize) type {
    return struct {
        fn restore(
            out: []i32,
            coefficients: []const i32,
            shift: u6,
            bits: u8,
        ) u64 {
            @setEvalBranchQuota(10_000);
            const limit = @as(i64, 1) << @intCast(bits - 1);
            var outside: u64 = 0;
            if (order == 0) {
                for (out) |sample| {
                    outside |= @as(u64, @bitCast(sample + limit))
                        >> @intCast(bits);
                }
                return outside;
            }
            var taps: [order]i64 = undefined;
            for (&taps, coefficients[0..order]) |*tap, coefficient|
                tap.* = coefficient;
            var ring: [order]i64 = undefined;
            for (&ring, out[0..order]) |*slot, sample| slot.* = sample;
            var index: usize = order;
            while (index + order <= out.len) : (index += order) {
                inline for (0..order) |step| {
                    var sum: i64 = 0;
                    inline for (0..order) |back| {
                        sum += taps[back]
                            * ring[(step + order - 1 - back) % order];
                    }
                    const value = (sum >> shift) + out[index + step];
                    outside |= @as(u64, @bitCast(value + limit))
                        >> @intCast(bits);
                    const stored: i32 = @truncate(value);
                    out[index + step] = stored;
                    ring[step] = stored;
                }
            }
            return outside
                | restoreScalar(
                    out[index - order..],
                    coefficients,
                    shift,
                    bits,
                );
        }
    };
}

/// orders above 12. the newest eight taps come from a register ring as in
/// unrolled; the older ones are at least eight samples old, so they can be
/// read back from memory four at a time without stalling on in-flight stores.
fn restoreWide(out: []i32, coefficients: []const i32, shift: u6, bits: u8) u64 {
    const near = 8;
    const lanes = 4;
    const far_count = coefficients.len - near;
    const padded = std.mem.alignForward(usize, far_count, lanes);
    var far: [24]i32 = @splat(0);
    for (0..far_count) |back|
        far[padded - 1 - back] = coefficients[near + back];
    var taps: [near]i64 = undefined;
    for (&taps, coefficients[0..near]) |*tap, coefficient| tap.* = coefficient;
    const head: usize = @min(near + padded, out.len);
    var outside = restoreScalar(out[0..head], coefficients, shift, bits);
    var ring: [near]i64 = undefined;
    for (&ring, out[head - near..head]) |*slot, sample| slot.* = sample;
    const limit = @as(i64, 1) << @intCast(bits - 1);
    var index = head;
    while (index + near <= out.len) : (index += near) {
        inline for (0..near) |step| {
            var products: @Vector(lanes, i64) = @splat(0);
            var lane: usize = 0;
            while (lane < padded) : (lane += lanes) {
                const history: @Vector(lanes, i32) = out[
                    index + step - near - padded + lane..
                ][
                    0..lanes
                ].*;
                const tap: @Vector(lanes, i32) = far[lane..][0..lanes].*;
                products += @as(@Vector(lanes, i64), history)
                    * @as(@Vector(lanes, i64), tap);
            }
            var sum: i64 = @reduce(.Add, products);
            inline for (0..near) |back| {
                sum += taps[back] * ring[(step + near - 1 - back) % near];
            }
            const value = (sum >> shift) + out[index + step];
            outside |= @as(u64, @bitCast(value + limit)) >> @intCast(bits);
            const stored: i32 = @truncate(value);
            out[index + step] = stored;
            ring[step] = stored;
        }
    }
    const rest = restoreScalar(
        out[index - coefficients.len..],
        coefficients,
        shift,
        bits,
    );
    return outside | rest;
}

/// one sample at a time from memory; handles heads and tails of the faster
/// paths. the first coefficients.len samples are history.
fn restoreScalar(
    out: []i32,
    coefficients: []const i32,
    shift: u6,
    bits: u8,
) u64 {
    const limit = @as(i64, 1) << @intCast(bits - 1);
    var outside: u64 = 0;
    for (coefficients.len..out.len) |index| {
        var sum: i64 = 0;
        for (coefficients, 0..) |coefficient, back| {
            sum += @as(i64, coefficient) * out[index - 1 - back];
        }
        const value = (sum >> shift) + out[index];
        outside |= @as(u64, @bitCast(value + limit)) >> @intCast(bits);
        out[index] = @truncate(value);
    }
    return outside;
}

/// msb-first reader over one crc-verified frame body; any overrun means the
/// frame is malformed.
const Bits = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn left(self: *const Bits) usize {
        return self.bytes.len * 8 - self.pos;
    }

    /// the next 57 or more bits, left aligned and zero padded past the end.
    fn window(self: *const Bits) u64 {
        const index = self.pos >> 3;
        const word = if (index + 8 <= self.bytes.len)
            std.mem.readInt(u64, self.bytes[index..][0..8], .big)
        else
            paddedWord(self.bytes[index..]);
        return word << @intCast(self.pos & 7);
    }

    fn paddedWord(rest: []const u8) u64 {
        @branchHint(.cold);
        var word: [8]u8 = @splat(0);
        @memcpy(word[0..rest.len], rest);
        return std.mem.readInt(u64, &word, .big);
    }

    fn read(self: *Bits, count: u32) error{ InvalidData }!u32 {
        std.debug.assert(count <= 32);
        if (count == 0) return 0;
        if (count > self.left()) return error.InvalidData;
        defer self.pos += count;
        return @intCast(self.window() >> @intCast(64 - count));
    }

    fn readSigned(self: *Bits, count: u32) error{ InvalidData }!i32 {
        const shift: u5 = @intCast(32 - count);
        return @as(i32, @bitCast(try self.read(count) << shift)) >> shift;
    }

    /// count zero bits up to and including a terminating one.
    fn unary(self: *Bits) error{ InvalidData }!u32 {
        var zeros: u32 = 0;
        while (true) {
            const available = @min(self.left(), 57);
            if (available == 0) return error.InvalidData;
            const run = @clz(self.window());
            if (run < available) {
                self.pos += run + 1;
                return zeros + run;
            }
            zeros += @intCast(available);
            self.pos += available;
        }
    }

    /// general path for one code, at any length and any distance from the end.
    fn rice(self: *Bits, parameter: u32) error{ InvalidData }!i32 {
        const quotient = try self.unary();
        const folded = @as(u64, quotient) << @intCast(parameter)
            | try self.read(parameter);
        return unfold(folded);
    }

    /// decode samples.len Rice codes. up to four codes share one window load,
    /// which takes the load out of the dependency chain; codes that do not fit
    /// in the window take the general path.
    fn riceBlock(
        self: *Bits,
        samples: []i32,
        parameter: u32,
    ) error{ InvalidData }!void {
        const group = 4;
        var index: usize = 0;
        while (
            index + group <= samples.len
                and (self.pos >> 3) + 8 <= self.bytes.len
        ) {
            var word = self.window();
            var have: u32 = 64 - @as(u32, @intCast(self.pos & 7));
            var taken: usize = 0;
            inline for (0..group) |lane| {
                const run: u32 = @clz(word);
                const used = run + 1 + parameter;
                if (used > have or used > 57) break;
                const rest = word << @intCast(run + 1) >> 1;
                const low = rest >> @intCast(63 - parameter);
                const folded = @as(u64, run) << @intCast(parameter) | low;
                samples[index + lane] = try unfold(folded);
                word <<= @intCast(used);
                have -= used;
                self.pos += used;
                taken += 1;
            }
            if (taken == 0) {
                samples[index] = try self.rice(parameter);
                taken = 1;
            }
            index += taken;
        }
        for (samples[index..]) |*sample| sample.* = try self.rice(parameter);
    }

    /// undo the zigzag fold; residuals must stay within 32 bits and may not
    /// be -2^31.
    fn unfold(folded: u64) error{ InvalidData }!i32 {
        if (folded > 0xFFFF_FFFE) return error.InvalidData;
        const magnitude: i32 = @intCast(folded >> 1);
        return magnitude ^ -@as(i32, @intCast(folded & 1));
    }
};

const testing = std.testing;
const Crc16 = std.hash.crc.Crc16Umts;

test "sliced crc matches the standard library at every length, offset and split" {
    var prng = std.Random.DefaultPrng.init(0xC2C);
    var data: [300]u8 = undefined;
    prng.random().bytes(&data);
    for (0..8) |offset| {
        const bytes = data[offset..];
        for (0..bytes.len + 1) |length| {
            const expected = Crc16.hash(bytes[0..length]);
            try testing.expectEqual(expected, crc16(0, bytes[0..length]));
            for ([_]usize{ 0, 1, 7, 8, 9, 100 }) |split| {
                if (split > length) continue;
                const head = crc16(0, bytes[0..split]);
                try testing.expectEqual(
                    expected,
                    crc16(head, bytes[split..length]),
                );
            }
        }
    }
}

fn restoreReference(
    out: []i32,
    coefficients: []const i32,
    shift: u6,
    bits: u8,
) error{ InvalidData }!void {
    const limit = @as(i64, 1) << @intCast(bits - 1);
    for (coefficients.len..out.len) |index| {
        var sum: i64 = 0;
        for (coefficients, 0..) |coefficient, back| {
            sum += @as(i64, coefficient) * out[index - 1 - back];
        }
        const value = (sum >> shift) + out[index];
        if (value < -limit or value >= limit) return error.InvalidData;
        out[index] = @intCast(value);
    }
}

test "every restore path matches the plain recurrence" {
    var prng = std.Random.DefaultPrng.init(0x5E57);
    const random = prng.random();
    for ([_]u8{ 8, 16, 24, 25 }) |bits| {
        const limit: i32 = @as(i32, 1) << @intCast(bits - 1);
        for ([_]bool{ true, false }) |stable| {
            for (0..33) |order| {
                for (
                    [_]usize{ order, order + 1, order + 5, 2 * order + 3, 90 },
                ) |length| {
                    if (length == 0 or length < order) continue;
                    var coefficients: [32]i32 = undefined;
                    for (coefficients[0..order]) |*coefficient| {
                        coefficient.* = if (stable)
                            random.intRangeAtMost(i32, -3, 3)
                        else
                            random.intRangeAtMost(i32, -16384, 16383);
                    }
                    const shift: u6 = if (stable)
                        8
                    else
                        random.uintLessThan(u6, 16);
                    const spread = if (stable) @divTrunc(limit, 8) else limit;
                    var expected: [128]i32 = undefined;
                    for (expected[0..length]) |*sample| {
                        sample.* = random.intRangeLessThan(
                            i32,
                            -spread,
                            spread,
                        );
                    }
                    var actual = expected;
                    const want = restoreReference(
                        expected[0..length],
                        coefficients[0..order],
                        shift,
                        bits,
                    );
                    const got = restore(
                        actual[0..length],
                        coefficients[0..order],
                        shift,
                        bits,
                    );
                    try testing.expectEqual(want, got);
                    if (want) |_| {
                        try testing.expectEqualSlices(
                            i32,
                            expected[0..length],
                            actual[0..length],
                        );
                    } else |_| {
                    }
                }
            }
        }
    }
}

/// assembles frames bit by bit with valid CRCs.
const Builder = struct {
    bytes: [8192]u8 = @splat(0),
    bits: usize = 0,
    variable: bool = false,

    fn put(self: *Builder, value: u64, count: u7) void {
        var index = count;
        while (index > 0) {
            index -= 1;
            if (value >> @intCast(index) & 1 != 0) {
                self.bytes[self.bits >> 3] |= @as(u8, 0x80)
                    >> @intCast(self.bits & 7);
            }
            self.bits += 1;
        }
    }

    fn putSigned(self: *Builder, value: i64, count: u7) void {
        const mask = (@as(u64, 1) << @intCast(count)) - 1;
        self.put(@as(u64, @bitCast(value)) & mask, count);
    }

    fn unary(self: *Builder, zeros: usize) void {
        self.bits += zeros;
        self.put(1, 1);
    }

    const Fields = struct {
        size: u4 = 6,
        rate: u4 = 9,
        assignment: u4 = 0,
        bits: u3 = 4,
    };

    fn header(self: *Builder, fields: Fields, tail: []const u8) void {
        self.put(@as(u16, 0xFFF8) | @intFromBool(self.variable), 16);
        self.put(@as(u8, fields.size) << 4 | fields.rate, 8);
        self.put(
            @as(u8, fields.assignment) << 4 | @as(u8, fields.bits) << 1,
            8,
        );
        for (tail) |byte| self.put(byte, 8);
        self.put(Crc8.hash(self.bytes[0..self.bits / 8]), 8);
    }

    /// mono or multichannel, 44.1 kHz, 16 bit, 16 samples.
    fn small(self: *Builder, assignment: u4) void {
        self.header(.{ .assignment = assignment }, &.{ 0, 15 });
    }

    fn subframe(self: *Builder, kind: u7, wasted: ?usize) void {
        self.put(0, 1);
        self.put(kind, 6);
        if (wasted) |count| {
            self.put(1, 1);
            self.unary(count - 1);
        } else {
            self.put(0, 1);
        }
    }

    fn finish(self: *Builder) []const u8 {
        self.bits = std.mem.alignForward(usize, self.bits, 8);
        self.put(Crc16.hash(self.bytes[0..self.bits / 8]), 16);
        return self.bytes[0..self.bits / 8];
    }

    fn written(self: *const Builder) []const u8 {
        return self.bytes[0..self.bits / 8];
    }
};

fn testCodec(channels: u16, bits: u8) !Self {
    return .{
        .allocator = testing.allocator,
        .config = .{ .max_block = 4096, .bits = bits },
        .format = .{ .sample_rate = 44100, .channels = channels },
        .planes = try testing.allocator.alloc(i32, channels * 4096),
        .scale = std.math.ldexp(@as(f32, 1), -@as(i32, bits - 1)),
    };
}

fn expectFrame(codec: *Self, frame: []const u8, expected: []const i32) !void {
    var out: [64]f32 = undefined;
    const frames = try codec.decodeUnit(frame, &out);
    try testing.expectEqual(expected.len, frames * codec.format.channels);
    for (expected, out[0..expected.len]) |want, got| {
        const value: i32 = @intFromFloat(got / codec.scale);
        try testing.expectEqual(want, value);
    }
}

fn expectFailure(codec: *Self, frame: []const u8, err: anyerror) !void {
    var out: [64]f32 = undefined;
    try testing.expectError(err, codec.decodeUnit(frame, &out));
}

fn pairs(left: i32, right: i32) [32]i32 {
    var result: [32]i32 = undefined;
    for (0..16) |index| {
        result[index * 2] = left;
        result[index * 2 + 1] = right;
    }
    return result;
}

const ramp = [_]i32{
    100,
    103,
    107,
    110,
    113,
    116,
    119,
    122,
    125,
    128,
    131,
    134,
    137,
    140,
    143,
    146,
};

/// residuals +1, -1 and twelve zeros (zigzag 2, 1, 0) after two warm-up
/// samples.
fn rampResidual(b: *Builder) void {
    b.put(0, 2);
    b.put(0, 4);
    b.put(0, 4);
    b.unary(2);
    b.unary(1);
    for (0..12) |_| b.unary(0);
}

test "constant subframe" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(0, null);
    b.putSigned(-1234, 16);
    try expectFrame(&codec, b.finish(), &([_]i32{-1234} ** 16));
}

test "final blocks may be shorter than 16 samples" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.header(.{}, &.{ 0, 4 });
    b.subframe(0, null);
    b.putSigned(77, 16);
    try expectFrame(&codec, b.finish(), &([_]i32{77} ** 5));

    b = Builder{};
    b.header(.{}, &.{ 0, 0 });
    b.subframe(1, null);
    b.putSigned(-9, 16);
    try expectFrame(&codec, b.finish(), &[_]i32{-9});

    b = Builder{};
    b.header(.{}, &.{ 0, 2 });
    b.subframe(9, null);
    b.putSigned(5, 16);
    b.put(0, 2);
    b.put(0, 4);
    b.put(0, 4);
    b.unary(0);
    b.unary(0);
    try expectFrame(&codec, b.finish(), &([_]i32{5} ** 3));
}

test "verbatim subframe with wasted bits" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(1, 3);
    var expected: [16]i32 = undefined;
    for (&expected, 0..) |*sample, index| {
        const value: i32 = @as(i32, @intCast(index)) * 7 - 50;
        b.putSigned(value, 13);
        sample.* = value * 8;
    }
    try expectFrame(&codec, b.finish(), &expected);
}

test "fixed predictor order 2" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(10, null);
    b.putSigned(100, 16);
    b.putSigned(103, 16);
    rampResidual(&b);
    try expectFrame(&codec, b.finish(), &ramp);
}

test "every fixed order extends a constant" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    for (0..5) |order| {
        var b = Builder{};
        b.small(0);
        b.subframe(@intCast(8 + order), null);
        for (0..order) |_| b.putSigned(-9, 16);
        b.put(0, 2);
        b.put(0, 4);
        b.put(0, 4);
        for (0..16 - order) |_| b.unary(0);
        const level: i32 = if (order == 0) 0 else -9;
        try expectFrame(&codec, b.finish(), &([_]i32{level} ** 16));
    }
}

test "lpc predictor matches the equivalent fixed predictor" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(33, null);
    b.putSigned(100, 16);
    b.putSigned(103, 16);
    b.put(3, 4);
    b.putSigned(1, 5);
    b.putSigned(4, 4);
    b.putSigned(-2, 4);
    rampResidual(&b);
    try expectFrame(&codec, b.finish(), &ramp);
}

test "lpc shift is arithmetic" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(33, null);
    b.putSigned(-3, 16);
    b.putSigned(-2, 16);
    b.put(1, 4);
    b.putSigned(1, 5);
    b.putSigned(1, 2);
    b.putSigned(0, 2);
    b.put(0, 2);
    b.put(0, 4);
    b.put(0, 4);
    for (0..14) |_| b.unary(0);
    const expected = [_]i32{ -3, -2 } ++ [_]i32{-1} ** 14;
    try expectFrame(&codec, b.finish(), &expected);
}

test "escaped partitions and five bit parameters" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(1, 2);
    b.put(1, 4);
    b.put(31, 5);
    b.put(3, 5);
    const raw = [_]i32{ 3, -4, 0, -1, 2, 1, -3, 3 };
    for (raw) |value| b.putSigned(value, 3);
    b.put(0, 5);
    for (0..8) |_| b.unary(0);
    try expectFrame(&codec, b.finish(), &(raw ++ [_]i32{0} ** 8));

    b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(1, 2);
    b.put(1, 4);
    b.put(31, 5);
    b.put(0, 5);
    b.put(1, 5);
    b.unary(1);
    b.put(1, 1);
    for (0..7) |_| {
        b.unary(0);
        b.put(0, 1);
    }
    const expected = [_]i32{0} ** 8 ++ [_]i32{-2} ++ [_]i32{0} ** 7;
    try expectFrame(&codec, b.finish(), &expected);
}

test "stereo channel assignments" {
    var codec = try testCodec(2, 16);
    defer codec.deinit();
    const cases = [_][2]i32{ .{ 101, 70 }, .{ -5, -8 }, .{ 32767, -32768 } };
    for (cases) |case| {
        const left = case[0];
        const right = case[1];
        const side = left - right;
        const mid = (left + right) >> 1;
        var b = Builder{};
        b.small(8);
        b.subframe(0, null);
        b.putSigned(left, 16);
        b.subframe(0, null);
        b.putSigned(side, 17);
        try expectFrame(&codec, b.finish(), &pairs(left, right));

        b = Builder{};
        b.small(9);
        b.subframe(0, null);
        b.putSigned(side, 17);
        b.subframe(0, null);
        b.putSigned(right, 16);
        try expectFrame(&codec, b.finish(), &pairs(left, right));

        b = Builder{};
        b.small(10);
        b.subframe(0, null);
        b.putSigned(mid, 16);
        b.subframe(0, null);
        b.putSigned(side, 17);
        try expectFrame(&codec, b.finish(), &pairs(left, right));
    }
}

test "independent channels keep their order" {
    var codec = try testCodec(3, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(2);
    for ([_]i64{ 1, -2, 3 }) |value| {
        b.subframe(0, null);
        b.putSigned(value, 16);
    }
    try expectFrame(&codec, b.finish(), &([_]i32{ 1, -2, 3 } ** 16));
}

test "frame header fields" {
    var b = Builder{};
    b.variable = true;
    b.header(
        .{ .size = 8, .rate = 12, .assignment = 1, .bits = 6 },
        &.{ 0xF0, 0x9F, 0x80, 0x80, 48 },
    );
    const header = try parseHeader(b.written());
    try testing.expect(header.variable);
    try testing.expectEqual(@as(u64, 0x1F000), header.number);
    try testing.expectEqual(@as(u32, 256), header.block_size);
    try testing.expectEqual(@as(?u32, 48000), header.sample_rate);
    try testing.expectEqual(@as(?u8, 24), header.bits);
    try testing.expectEqual(@as(u16, 2), header.channels());
    try testing.expectEqual(b.bits / 8, header.len);

    b = Builder{};
    b.header(
        .{ .size = 7, .rate = 14, .assignment = 8, .bits = 0 },
        &.{ 0x7F, 0x03, 0xFF, 0x00, 0x2C },
    );
    const uncommon = try parseHeader(b.written());
    try testing.expect(!uncommon.variable);
    try testing.expectEqual(@as(u64, 0x7F), uncommon.number);
    try testing.expectEqual(@as(u32, 1024), uncommon.block_size);
    try testing.expectEqual(@as(?u32, 440), uncommon.sample_rate);
    try testing.expectEqual(@as(?u8, null), uncommon.bits);
}

test "coded numbers" {
    const longest = [_]u8{ 0xFE, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF };
    var b = Builder{};
    b.variable = true;
    b.header(.{ .size = 1 }, &longest);
    const header = try parseHeader(b.written());
    try testing.expectEqual((@as(u64, 1) << 36) - 1, header.number);

    b = Builder{};
    b.header(.{ .size = 1 }, &longest);
    try testing.expectError(error.InvalidData, parseHeader(b.written()));

    const malformed = [_][]const u8{
        &.{0x80},
        &.{ 0xC0, 0x00 },
        &.{ 0xFF, 0x80 },
    };
    for (malformed) |tail| {
        b = Builder{};
        b.variable = true;
        b.header(.{ .size = 1 }, tail);
        try testing.expectError(error.InvalidData, parseHeader(b.written()));
    }
}

test "invalid headers" {
    const cases = [_]struct { u4, u4, u4, u3 }{
        .{ 0, 9, 0, 4 },
        .{ 1, 15, 0, 4 },
        .{ 1, 9, 11, 4 },
        .{ 1, 9, 0, 3 },
    };
    for (cases) |case| {
        var b = Builder{};
        b.header(
            .{
                .size = case[0],
                .rate = case[1],
                .assignment = case[2],
                .bits = case[3],
            },
            &.{0},
        );
        try testing.expectError(error.InvalidData, parseHeader(b.written()));
    }
    var b = Builder{};
    b.small(0);
    const length = b.bits / 8;
    var bytes = b.bytes;
    bytes[3] |= 1;
    try testing.expectError(error.InvalidData, parseHeader(bytes[0..length]));
    bytes = b.bytes;
    bytes[4] ^= 1;
    try testing.expectError(error.InvalidData, parseHeader(bytes[0..length]));
}

test "every header prefix is truncated, never invalid" {
    var b = Builder{};
    b.header(
        .{ .size = 7, .rate = 13, .assignment = 1, .bits = 5 },
        &.{ 0xC2, 0xA0, 0x01, 0x00, 0xAC, 0x44 },
    );
    const length = b.bits / 8;
    for (0..length) |prefix| {
        try testing.expectError(
            error.TruncatedData,
            parseHeader(b.bytes[0..prefix]),
        );
    }
    _ = try parseHeader(b.bytes[0..length]);
}

test "malformed subframes" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();

    var b = Builder{};
    b.small(0);
    b.put(1, 1);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    for ([_]u7{ 2, 7, 13, 31 }) |kind| {
        b = Builder{};
        b.small(0);
        b.subframe(kind, null);
        b.put(0, 40);
        try expectFailure(&codec, b.finish(), error.InvalidData);
    }

    b = Builder{};
    b.small(0);
    b.subframe(0, 16);
    b.put(0, 16);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(33, null);
    b.put(0, 32);
    b.put(3, 4);
    b.putSigned(-1, 5);
    b.put(0, 32);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(33, null);
    b.put(0, 32);
    b.put(15, 4);
    b.put(0, 64);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(0, 2);
    b.put(5, 4);
    b.put(0, 64);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(2, 2);
    b.put(0, 64);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(12, null);
    b.put(0, 64);
    b.put(0, 2);
    b.put(3, 4);
    b.put(0, 64);
    try expectFailure(&codec, b.finish(), error.InvalidData);
}

test "residual limits" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();

    var b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(1, 2);
    b.put(0, 4);
    b.put(30, 5);
    b.unary(3);
    b.put((1 << 30) - 1, 30);
    for (0..15) |_| {
        b.unary(0);
        b.put(0, 30);
    }
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(0, 2);
    b.put(0, 4);
    b.put(4, 4);
    b.unary(4300);
    b.put(0, 4);
    for (0..15) |_| {
        b.unary(0);
        b.put(0, 4);
    }
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(9, null);
    b.putSigned(32767, 16);
    b.put(0, 2);
    b.put(0, 4);
    b.put(0, 4);
    b.unary(2);
    for (0..14) |_| b.unary(0);
    try expectFailure(&codec, b.finish(), error.InvalidData);
}

test "init rejects unsupported configurations" {
    const stereo = types.AudioFormat{ .sample_rate = 44100, .channels = 2 };
    const bad_channels = [_]u16{ 0, 9 };
    for (bad_channels) |channels| {
        const format = types.AudioFormat{
            .sample_rate = 44100,
            .channels = channels,
        };
        try testing.expectError(
            error.InvalidData,
            init(
                testing.allocator,
                .{ .max_block = 4096, .bits = 16 },
                format,
                .{},
            ),
        );
    }
    try testing.expectError(
        error.UnsupportedEncoding,
        init(
            testing.allocator,
            .{ .max_block = 4096, .bits = 32 },
            stereo,
            .{},
        ),
    );
    try testing.expectError(
        error.InvalidData,
        init(testing.allocator, .{ .max_block = 4096, .bits = 3 }, stereo, .{}),
    );
    try testing.expectError(
        error.InvalidData,
        init(testing.allocator, .{ .max_block = 15, .bits = 16 }, stereo, .{}),
    );
}
test "partition count must divide the block size" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    @memset(codec.planes, 0);
    var b = Builder{};
    b.header(.{}, &.{ 0, 16 });
    b.subframe(8, null);
    b.put(0, 2);
    b.put(1, 4);
    for (0..2) |_| {
        b.put(0, 4);
        for (0..8) |_| b.unary(0);
    }
    try expectFailure(&codec, b.finish(), error.InvalidData);
}
test "forbidden fields are rejected in otherwise valid frames" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(33, null);
    b.put(0, 32);
    b.put(15, 4);
    b.put(0, 5);
    b.put(0, 32);
    b.put(0, 2);
    b.put(0, 4);
    b.put(0, 4);
    for (0..14) |_| b.unary(0);
    try expectFailure(&codec, b.finish(), error.InvalidData);

    b = Builder{};
    b.small(0);
    b.subframe(8, null);
    b.put(2, 2);
    b.put(0, 4);
    b.put(0, 5);
    for (0..16) |_| b.unary(0);
    try expectFailure(&codec, b.finish(), error.InvalidData);
}
test "frame level errors" {
    var codec = try testCodec(1, 16);
    defer codec.deinit();
    var b = Builder{};
    b.small(0);
    b.subframe(0, null);
    b.putSigned(5, 16);
    const frame = b.finish();
    try expectFrame(&codec, frame, &([_]i32{5} ** 16));

    var copy: [64]u8 = undefined;
    @memcpy(copy[0..frame.len], frame);
    copy[frame.len - 3] ^= 0x10;
    try expectFailure(&codec, copy[0..frame.len], error.InvalidData);
    try expectFailure(&codec, frame[0..frame.len - 1], error.InvalidData);
    try expectFailure(&codec, frame[0..frame.len - 2], error.InvalidData);
    try expectFailure(&codec, frame[0..3], error.TruncatedData);
    try expectFailure(&codec, &.{}, error.TruncatedData);

    var stereo = try testCodec(2, 16);
    defer stereo.deinit();
    try expectFailure(&stereo, frame, error.UnsupportedEncoding);

    var deep = try testCodec(1, 24);
    defer deep.deinit();
    try expectFailure(&deep, frame, error.UnsupportedEncoding);

    var rate = try testCodec(1, 16);
    defer rate.deinit();
    rate.format.sample_rate = 48000;
    try expectFailure(&rate, frame, error.UnsupportedEncoding);

    b = Builder{};
    b.header(.{ .size = 13 }, &.{0});
    b.subframe(0, null);
    b.putSigned(0, 16);
    try expectFailure(&codec, b.finish(), error.LimitExceeded);
}

test "bit reader" {
    var b = Bits{ .bytes = &.{ 0xA5, 0x0F, 0xF0, 0x80 } };
    try testing.expectEqual(@as(u32, 0b101), try b.read(3));
    try testing.expectEqual(@as(i32, 10), try b.readSigned(6));
    try testing.expectEqual(@as(u32, 63), try b.read(9));
    try testing.expectEqual(@as(u32, 0), try b.read(0));
    try testing.expectEqual(@as(u32, 0), try b.unary());
    try testing.expectEqual(@as(u32, 0), try b.unary());
    try testing.expectEqual(@as(u32, 4), try b.unary());
    try testing.expectError(error.InvalidData, b.unary());
    try testing.expectError(error.InvalidData, b.read(1));

    var negative = Bits{ .bytes = &.{ 0xF0, 0xFF, 0xFF, 0xFE } };
    try testing.expectEqual(@as(i32, -1), try negative.readSigned(4));
    try testing.expectEqual(@as(i32, 0), try negative.readSigned(4));
    try testing.expectEqual(@as(i32, -2), try negative.readSigned(24));
}

test "unary spans many windows" {
    var bytes: [40]u8 = @splat(0);
    bytes[30] = 0x10;
    var b = Bits{ .bytes = &bytes };
    try testing.expectEqual(@as(u32, 30 * 8 + 3), try b.unary());
    try testing.expectError(error.InvalidData, b.unary());
}

test "garbage frames with valid checksums never crash" {
    var prng = std.Random.DefaultPrng.init(0xF1AC);
    const random = prng.random();
    const sizes = [_]u4{ 1, 2, 3, 4, 5, 8, 9, 10, 11, 12 };
    const stereo = [_]u4{ 1, 8, 9, 10 };
    for ([_]u8{ 4, 8, 16, 24 }) |depth| {
        for ([_]u16{ 1, 2, 5 }) |channels| {
            var codec = try testCodec(channels, depth);
            defer codec.deinit();
            const out = try testing.allocator.alloc(f32, 4096 * 8);
            defer testing.allocator.free(out);
            for (0..3000) |_| {
                var b = Builder{};
                const assignment: u4 = switch (channels) {
                    2 => stereo[random.uintLessThan(usize, stereo.len)],
                    else => @intCast(channels - 1),
                };
                const size = sizes[random.uintLessThan(usize, sizes.len)];
                b.header(
                    .{ .size = size, .assignment = assignment, .bits = 0 },
                    &.{0},
                );
                const start = b.bits / 8;
                const length = random.uintLessThan(usize, 600);
                random.bytes(b.bytes[start..][0..length]);
                b.bits = (start + length) * 8;
                _ = codec.decodeUnit(b.finish(), out) catch continue;
            }
        }
    }
}
