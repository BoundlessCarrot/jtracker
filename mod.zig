const std = @import("std");
const helpers = @import("helpers.zig");
const types = @import("types.zig");

const Sample = types.Sample;
const Note = types.Note;
const Mod = types.Mod;

/// Upper bound for a MOD file. 31 samples at the 128 KiB maximum
/// plus 128 patterns is a little over 4 MiB, so this leaves headroom
/// for multichannel variants.
const max_mod_size = 8 * 1024 * 1024;

/// Reads a MOD file into memory. Caller owns the returned slice.
fn readModFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_mod_size)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooBig,
        else => |e| return e,
    };
    std.log.debug("read {s}, {d} bytes", .{ path, buf.len });
    return buf;
}

/// Maps a MOD signature tag (bytes 1080..1084) to a channel count.
/// Handles the common ProTracker/Fasttracker variants: "M.K.", "M!K!",
/// "FLT4", "nCHN", and "nnCH".
fn channelsFromSignature(sig: []const u8) u32 {
    if (std.mem.eql(u8, sig, "M.K.") or std.mem.eql(u8, sig, "M!K!") or
        std.mem.eql(u8, sig, "FLT4") or std.mem.eql(u8, sig, "PATT"))
        return 4;
    if (std.mem.eql(u8, sig, "OCTA") or std.mem.eql(u8, sig, "CD81") or
        std.mem.eql(u8, sig, "FLT8"))
        return 8;
    if (sig[1] == 'C' and sig[2] == 'H' and sig[3] == 'N' and std.ascii.isDigit(sig[0]))
        return sig[0] - '0'; // "nCHN"
    if (sig[2] == 'C' and sig[3] == 'H' and std.ascii.isDigit(sig[0]) and std.ascii.isDigit(sig[1]))
        return (@as(u32, sig[0] - '0') * 10) + (sig[1] - '0'); // "nnCH"
    return 4; // unknown signature, assume the common case
}

/// Parses a MOD header and puts it into the MOD type
pub fn modLoad(alloc: std.mem.Allocator, buf: []const u8) !Mod {
    const numPatterns: u32 = std.mem.max(u8, buf[952..1080]) + 1;
    const numChannels: u32 = channelsFromSignature(buf[1080..1084]);
    const patternDataEndIdx: usize = 1084 + @as(usize, numPatterns) * 64 * numChannels * 4;

    const sampleHeaders = buf[20..950];
    const sampleData = buf[patternDataEndIdx..];

    var samples: [31]Sample = undefined;
    var chunked = std.mem.window(u8, sampleHeaders, 30, 30);
    var sampleDataOffset: usize = 0;
    var i: usize = 0;
    while (chunked.next()) |chunk| : (i += 1) {
        // Lengths/loop points are stored as big-endian word counts; convert to bytes.
        const length = @as(u32, std.mem.readInt(u16, chunk[22..24], .big)) * 2;
        const loopStart = @as(u32, std.mem.readInt(u16, chunk[26..28], .big)) * 2;
        const loopLength = @as(u32, std.mem.readInt(u16, chunk[28..30], .big)) * 2;

        // Finetune is a signed 4-bit nibble (-8..7) stored in the low bits.
        const rawFinetune = chunk[24] & 0x0F;
        const finetune: i8 = if (rawFinetune >= 8)
            @as(i8, @intCast(rawFinetune)) - 16
        else
            @as(i8, @intCast(rawFinetune));

        const data = sampleData[sampleDataOffset..][0..length];
        sampleDataOffset += length;

        samples[i] = .{
            .name = chunk[0..22].*,
            .length = length,
            .finetune = finetune,
            .volume = chunk[25],
            .loop_start = loopStart,
            .loop_length = loopLength,
            .data = @ptrCast(data),
        };
    }

    var title: [21]u8 = @splat(0);
    @memcpy(title[0..20], buf[0..20]);

    // Each note is 4 packed bytes:
    //   byte0 = sample hi-nibble | period hi-nibble
    //   byte1 = period lo-byte
    //   byte2 = sample lo-nibble | effect
    //   byte3 = param
    const noteBytes = buf[1084..patternDataEndIdx];
    const notes = try alloc.alloc(Note, noteBytes.len / 4);
    for (notes, 0..) |*note, n| {
        const b = noteBytes[n * 4 ..][0..4];
        note.* = .{
            .sample = (b[0] & 0xF0) | (b[2] >> 4),
            .period = (@as(u16, b[0] & 0x0F) << 8) | @as(u16, b[1]),
            .effect = b[2] & 0x0F,
            .param = b[3],
        };
    }

    const modHeader: Mod = .{
        .title = title,
        .samples = samples,
        .song_length = buf[950],
        .orders = buf[952..1080].*,
        .num_patterns = numPatterns,
        .num_channels = numChannels,
        .notes = notes,
    };

    return modHeader;
}

test "readModFile reads the file" {
    const gpa = std.testing.allocator;
    const buf = try readModFile(gpa, std.testing.io, "space_debris.mod");
    defer gpa.free(buf);
    try std.testing.expectEqual(347582, buf.len * @sizeOf(u8));
}

test "modLoad parses space_debris.mod" {
    const gpa = std.testing.allocator;
    const buf = try readModFile(gpa, std.testing.io, "space_debris.mod");
    defer gpa.free(buf);
    const m = try modLoad(gpa, buf);
    defer gpa.free(m.notes);

    const t = std.testing;

    // Header
    try t.expectEqualStrings("space_debris", std.mem.sliceTo(&m.title, 0));
    try t.expectEqual(42, m.song_length);
    try t.expectEqual(41, m.num_patterns);        // highest order (40) + 1
    try t.expectEqual(4, m.num_channels);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 10 }, m.orders[0..4]);

    // Lengths add up to exactly the end of the file
    var total: u32 = 0;
    for (m.samples) |s| total += s.length;
    try t.expectEqual(304514, total);

    // One-shot, looped, empty, and the sample after the empty one
    try t.expectEqualStrings("SuperHyperBass", std.mem.sliceTo(&m.samples[0].name, 0));
    try t.expectEqual(7680, m.samples[0].length);
    try t.expectEqual(52, m.samples[0].volume);
    try t.expectEqual(2, m.samples[4].loop_start);
    try t.expectEqual(35568, m.samples[4].loop_length);
    try t.expectEqual(0, m.samples[10].length);
    try t.expectEqual(65430, m.samples[11].length);

    // Data offsets: after the gap, and the last bytes of the file
    try t.expectEqualSlices(i8, &.{ 0, 0, -1, -2 }, m.samples[11].data[0..4]);
    try t.expectEqualSlices(i8, &.{ 1, 1, 1, 1 }, m.samples[17].data[3996..]);

    // One decoded cell
    try t.expectEqual(Note{ .sample = 1, .period = 320, .effect = 0xF, .param = 0x06 }, m.notes[0]);

    helpers.PrintModHelpers.patternPrinter(m, 1);
}
