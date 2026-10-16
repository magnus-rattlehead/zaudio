pub const types = @import("types.zig");
pub const parse = wave.parse;
pub const wave64 = wave.wave64;
pub const wav = wave.wav;
pub const Decoder = @import("Decoder.zig");
pub const DataRange = types.DataRange;
pub const AudioData = types.AudioData;
pub const Segment = types.Segment;
pub const Info = types.Info;
pub const Format = types.Format;
pub const DecodeError = types.DecodeError;
pub const ParseError = types.ParseError;
pub const ReadError = types.ReadError;
pub const SeekError = types.SeekError;
pub const SizeError = types.SizeError;
pub const IoError = types.IoError;
pub const ValidationError = types.ValidationError;
pub const SourceSeekError = types.SourceSeekError;
pub const ParserError = types.ParserError;
pub const DecoderError = types.DecoderError;
pub const ParsedAudio = types.ParsedAudio;
pub const DecodingScheme = types.DecodingScheme;
pub const PcmFormat = types.PcmFormat;
pub const PcmSampleType = types.PcmSampleType;
pub const Source = @import("Source.zig");
pub const PacketSource = @import("PacketSource.zig");
pub const Codec = @import("Codec.zig");
pub const Framer = Codec.Framer;
pub const OpusConfig = types.OpusConfig;
pub const VorbisConfig = types.VorbisConfig;
pub const FlacConfig = types.FlacConfig;
pub const wave = @import("containers/wave/root.zig");
pub const ogg = @import("containers/ogg/root.zig");

test {
    _ = @import("codecs/flac.zig");
    _ = @import("containers/Flac.zig");
}
