//! Shared data types for a parsed MOD file.

/// One instrument's header fields plus its raw 8-bit sample data.
///
/// Used in:
/// - `mod.zig`: held in `Mod.samples`; filled in by `modLoad` from the
///   31 sample headers (bytes 20..950) and the sample data region that
///   follows the pattern data.
/// - `mod.zig` tests: inspected directly (`m.samples[n]`) to check header
///   parsing, finetune/volume decoding, and sample data offsets.
pub const Sample = struct {
    name: [22]u8, // 22 chars (+ terminator?)
    length: u32, // in bytes
    finetune: i8, // -8..7
    volume: u8, // 0..64
    loop_start: u32, // in bytes
    loop_length: u32, // in bytes, less than/equal to 2 means no loop
    data: []const i8,
};

/// One decoded pattern cell: a sample number, a period (pitch), and an
/// effect/parameter pair, unpacked from 4 packed bytes of pattern data.
///
/// Used in:
/// - `mod.zig`: held in `Mod.notes`; decoded from the packed pattern bytes
///   in `modLoad`.
/// - `helpers.zig`: `PrintModHelpers.printCell` and `.modNote` read a
///   `Note` to render it as text for `patternPrinter`.
/// - `mod.zig` tests: one decoded cell (`m.notes[0]`) is checked against
///   the worked example from the guide.
pub const Note = struct {
    sample: u8, // 0 = none, 1..31
    period: u16, // 0 = none
    effect: u8, // 0x0..0xF
    param: u8, // 0x00..0xFF
};

/// A fully parsed MOD file: title, all 31 sample slots, the order list,
/// and the flat pattern/note data.
///
/// Used in:
/// - `mod.zig`: returned by `modLoad`, the module's public entry point
///   for loading a `.mod` file into memory.
/// - `helpers.zig`: `PrintModHelpers.patternPrinter` and `.modNote` take a
///   `Mod` to print one pattern as text.
/// - `mod.zig` tests: asserted against directly after loading
///   `space_debris.mod`, and passed to `patternPrinter` to print pattern 1.
pub const Mod = struct {
    title: [21]u8,
    samples: [31]Sample,
    song_length: u32, // unsure about the type here, in the guide it's just `int`
    orders: [128]u8,
    num_patterns: u32,
    num_channels: u32,
    notes: []Note, // num_patterns * 64 * num_channels
};

pub const Channel = struct {
    sample: Sample, // The instrument, kept even while silent
    active: u32, // 0 = no sound
    inLoop: u32, // 0 on first pass thru the sample
    pos: u64,
    step: u64,
    period: u16,
    volume: u32
};