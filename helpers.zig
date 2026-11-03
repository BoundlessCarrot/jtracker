const std = @import("std");
const types = @import("types.zig");

const print = std.debug.print;

const periods: [36]u16 = .{
//   C    C#   D    D#   E    F    F#   G    G#   A    A#   B
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, // octave 1
    428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226, // octave 2
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113, // octave 3
};

const noteNames: [12][]const u8 = .{
    "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"
};

pub const PrintModHelpers = struct {
    fn periodIdx(period: u16) ?u16 {
        for (0..36) |n| {
            if (periods[n] == period) return @intCast(n);
        }
        return null;
    }

    fn printCell(note: types.Note) void {
        if (note.period == 0) {
            print("---", .{});
        } else if (periodIdx(note.period)) |i| {
            print("{s}{d}", .{ noteNames[i % 12], i / 12 + 1 });
        } else {
            print("???", .{});
        }

        if (note.sample != 0) {
            print(" {X:02}", .{note.sample});
        } else {
            print(" --", .{});
        }

        if (note.effect != 0 or note.param != 0) {
            print(" {X}{X:02}", .{note.effect, note.param});
        } else {
            print(" ---", .{});
        }
    }

    fn modNote(m: types.Mod, pattern: usize, row: usize, ch: usize) types.Note {
        return m.notes[(pattern * 64 + row) * m.num_channels + ch];
    }

    pub fn patternPrinter(header: types.Mod, pattern: usize) void {
        for (0..64) |row| {
            print("{d:02} ", .{row});
            for (0..header.num_channels) |ch| {
                print("| ", .{});
                printCell(modNote(header, pattern, row, ch));
                print(" ", .{});
            }
            print("\n", .{});
        }
    }
};
