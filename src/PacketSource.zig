//! read container bytes as encoded packets and timing events.
const std = @import("std");
const types = @import("types.zig");
const Source = @import("Source.zig");
const Wave = @import("containers/wave/root.zig").Reader;
const Ogg = @import("containers/ogg/root.zig").Reader;
const Flac = @import("containers/Flac.zig");
const PacketSource = @This();

pub const Error = types.Error;

const Backend = union(enum) { wave: *Wave, ogg: *Ogg, flac: *Flac };
const containers = .{ Wave, Ogg, Flac };

backend: Backend,
encoding: types.DecodingScheme,
format: types.AudioFormat,
presentation: types.Presentation = .{},
/// first decoded sample position before trimming.
decoded_origin: i64 = 0,
seekable: bool,
max_payload_bytes: usize = 64 * 1024 * 1024,

pub const Event = union(enum) {
    packet: types.Packet,
    /// send final trim bounds before the affected packets.
    presentation: types.Presentation,
    /// repeat the last frame without advancing codec state.
    silence: u64,
    end,
};

pub const SeekResult = struct { frame: i64 };

/// detect and open a container; allocate buffers and any seek index.
/// seekable input may be indexed; sequential input is parsed incrementally.
pub fn init(
    allocator: std.mem.Allocator,
    source: Source,
    options: types.Options,
) Error!PacketSource {
    const seekable = source.seek_to != null
        and source.get_size != null
        and try source.getSize() != null;
    if (seekable) try source.seekTo(0);
    var prefix: [4]u8 = undefined;
    if (try source.reader.readSliceShort(&prefix) != prefix.len) {
        return error.UnsupportedFormat;
    }
    inline for (containers) |Container| {
        if (Container.probe(&prefix)) {
            return Container.init(allocator, source, prefix, options);
        }
    }
    return error.UnsupportedFormat;
}

/// open an unchanged parsed wav layout; requires seeking and size.
pub fn initParsed(
    allocator: std.mem.Allocator,
    source: Source,
    parsed: types.ParsedAudio,
    options: types.Options,
) Error!PacketSource {
    return Wave.initParsed(allocator, source, parsed, options);
}

/// set framing before requesting packets.
pub fn configure(self: *PacketSource, scheme: types.InputScheme) Error!void {
    switch (self.backend) {
        inline else => |container| try container.configure(scheme),
    }
}

/// borrow a packet until the next advancing source operation.
pub fn next(self: *PacketSource) Error!Event {
    const event = switch (self.backend) {
        inline else => |container| try container.next(),
    };
    if (event == .packet) {
        if (event.packet.bytes.len == 0) return error.InvalidData;
        if (event.packet.bytes.len > self.max_payload_bytes) {
            return error.LimitExceeded;
        }
    }
    return event;
}

/// return metadata with untrimmed frame counts.
pub fn info(self: *const PacketSource) types.Info {
    return switch (self.backend) {
        inline else => |container| container.info(),
    };
}

/// seek at or before a frame, preserving prior data needed for held silence.
pub fn seek(self: *PacketSource, frame: u64) Error!SeekResult {
    if (!self.seekable) return error.Unseekable;
    return switch (self.backend) {
        inline else => |container| container.seek(frame),
    };
}

/// free packet storage and parser state; leave input open.
pub fn deinit(self: *PacketSource) void {
    switch (self.backend) {
        inline else => |container| container.deinit(),
    }
    self.* = undefined;
}
