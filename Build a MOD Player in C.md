# Build a MOD Player in C

Oct 14, 2026 · @Jordan S

## Introduction

By the end of this guide you will have a program that loads a `.mod` file from 1990 and plays it through your speakers. The finished player is around 600 lines of C, and every one of them is something you write.

MOD files come from the Amiga. In 1987 a program called Ultimate Soundtracker let people compose music by typing notes into a grid, and the file format it saved became the standard for a whole generation of game and demoscene music. Tens of thousands of these songs are still freely available on [The Mod Archive](https://modarchive.org). Because the format is simple and fully documented, a MOD player is one of the best ways to learn how digital audio actually works.

This is Part 1 of a series. Here we build the **player**. In Part 2 we add an editor on top of it and turn it into a real tracker. Later, the same player gets dropped into a demo as its soundtrack, so we will keep it as a small library with a clean interface from the start.

### What you need

- A C compiler (`cc`, `gcc` or `clang`) and comfort reading C.
- Basic binary arithmetic: shifts, masks, two's complement.
- [SDL3](https://libsdl.org) for audio output. On macOS: `brew install sdl3`. You will not need it until the section on real-time output.
- A few `.mod` files. Start with a small 4-channel song from The Mod Archive. Anything with the `M.K.` signature works.

### How to use this guide

Each section explains a concept, shows you the relevant part of the format, and then hands you a task. Boring setup code (WAV headers, SDL boilerplate) is given in full, because you learn nothing by retyping it. The interesting parts are explained and then left to you, with pseudocode or a skeleton where it helps.

When a task is the kind of thing you might get stuck on, it ends with a **Hint** you can read first and a pointer to the **Cheat sheet** at the end, which holds a working answer. Try the task before you look. The struggle is where the learning happens.

> **Note:** We aim for *ProTracker 2.x* behaviour. There are many MOD variants and many players disagree on edge cases. ProTracker is the closest thing to a reference, and most songs were written to sound right in it.

> **Note:** The behaviour described here was checked against [pt2-clone](https://github.com/8bitbubsy/pt2-clone), a C port of the ProTracker 2.3D replayer, and against the original ProTracker format notes. Where players disagree, this guide follows ProTracker.

You will also find two kinds of side notes. **Shortcut** notes tell you what you can skip or simplify to hear sound sooner. **Speedup** notes point out where a real player would optimise. None of them are required.

### Suggested file layout

```
mod.h      // public API: structs + functions the demo will call later
mod.c      // loader + sequencer + mixer
wav.c      // write a WAV file (given in full)
main.c     // command line: render to WAV or play through SDL3
```

The public API we are working toward is tiny:

```c
int  mod_load(Mod *mod, const char *path);          // 1 on success
void player_init(Player *p, const Mod *mod, int sample_rate);
void player_render(Player *p, int16_t *out, int frames); // stereo, interleaved
void mod_free(Mod *mod);
```

Everything else lives behind `player_render`. Whoever calls it (a WAV writer, an SDL callback, a demo) just asks for the next chunk of audio.

## What is a tracker?

A tracker is a music program where time runs **down the screen** instead of across it. You type notes into a grid, and a cursor moves down one line at a time, playing whatever it finds. Here is what a few rows of a MOD look like in a tracker:

```
Row | Channel 1    | Channel 2    | Channel 3    | Channel 4
----+--------------+--------------+--------------+-------------
 00 | C-2 01 C40   | --- -- ---   | E-2 03 000   | --- -- ---
 01 | --- -- A02   | --- -- ---   | --- -- 000   | --- -- ---
 02 | --- -- A02   | G-1 02 000   | --- -- 000   | C-3 04 C20
 03 | --- -- A02   | --- -- ---   | --- -- 000   | --- -- ---
 04 | D#2 01 000   | --- -- ---   | G-2 03 000   | --- -- ---
```

Each cell has three parts: a **note** (`C-2` means C in octave 2), a **sample number** (`01`, which instrument to play) and an **effect** (`C40`, an instruction that modifies how the note plays). Empty cells mean "keep doing what you were doing".

A few terms you will see everywhere:

- **Sample**: a short recording of an instrument, stored as raw 8-bit audio. A MOD holds up to 31 of them.
- **Channel**: one voice. Each channel plays at most one sample at a time. Classic MODs have 4 channels, because the Amiga's sound chip had 4.
- **Row**: one line of the grid. All channels advance one row together.
- **Pattern**: a block of 64 rows. Think of it as a few bars of music.
- **Order list** (or *song positions*): the sequence in which patterns are played. A chorus written once as pattern 3 can appear in the order list five times.

So a song is a list of pattern numbers, each pattern is 64 rows, and each row is one cell per channel. Playing a MOD means walking that structure while turning each cell into sound.

If you think back to the LC-3, the analogy is close. The order list and row counter are the program counter. Each cell is an instruction. Effects are opcodes. The sound chip is the hardware we simulate.

> **Note:** Install a real tracker such as [MilkyTracker](https://milkytracker.org) or [OpenMPT](https://openmpt.org) and open a song. Watching the grid scroll while the music plays will make everything in this guide click faster. You will also use it later to check your player's output.

## How the Amiga made sound

The MOD format is a snapshot of how the Amiga's sound chip, **Paula**, worked. Understanding the chip explains almost every strange choice in the file format.

Paula had 4 channels. Each one was given three things: a pointer to some 8-bit sample data in memory, a volume from 0 to 64, and a **period**. Paula then fetched the sample data from memory on its own and played it one byte at a time. Two channels went to the left speaker and two went to the right.

### Periods, not frequencies

The period is the number of clock ticks Paula waits before reading the next sample byte. A **larger period means a slower read, which means a lower pitch.** This is backwards from how we normally think about notes, so keep it in mind. A slide *up* in pitch is a period going *down*.

To turn a period into the playback rate in Hz:

```latex
f = \frac{7093789.2}{2 \times \text{period}} \approx \frac{3546895}{\text{period}}
```

The 7093789.2 Hz figure is the clock of a PAL Amiga. American NTSC machines ran slightly faster, but nearly all MODs were made on PAL machines, so use the PAL value.

Notice that this is the rate at which the **sample** is read, not the pitch of the musical note. If an instrument was recorded at a C, playing it back at a different rate shifts it to a different note. That is all pitch is in a tracker: the same recording read faster or slower.

### The period table

ProTracker only lets you enter 36 notes, three octaves of 12. Each note maps to a fixed period:

```c
/* C    C#   D    D#   E    F    F#   G    G#   A    A#   B   */
static const uint16_t PERIODS[36] = {
  856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, /* octave 1 */
  428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226, /* octave 2 */
  214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113, /* octave 3 */
};
```

Copy this table into your code. You will use it to print note names and later to implement arpeggios. Look at the pattern: each octave is roughly half the period of the one before, and each semitone is the previous period divided by about 1.0595 (the twelfth root of 2).

> **Note:** The file stores the raw period, not the note name. That is why you need this table to show `C-2` instead of `428`. Some files contain periods that are not in the table at all. Your player should play them anyway. Only the display needs the table.

### What we simulate

We do not need to emulate Paula cycle by cycle. We need one thing from it: for each channel, step through the sample data at the rate given by the period, scale by the volume, and add the channels together. The rest of this guide is mostly about *when* the period, volume and sample pointer change.

## The MOD file format

A MOD file is a fixed-size header, followed by pattern data, followed by raw sample data. There are no chunks, no tags and no compression. If you know the offsets, you can read it with nothing but pointer arithmetic.

### Layout

| Offset | Size | Contents |
| --- | --- | --- |
| 0 | 20 | Song title, padded with zeros |
| 20 | 31 × 30 | Sample headers (see below) |
| 950 | 1 | Song length: how many entries of the order list are used (1 to 128) |
| 951 | 1 | Restart position. Ignore it. |
| 952 | 128 | Order list: one pattern number per song position |
| 1080 | 4 | Signature, usually `M.K.` |
| 1084 | patterns × 64 × channels × 4 | Pattern data |
| after patterns | sum of sample lengths | Sample data, 8-bit signed, in sample order |

Each 30-byte sample header looks like this:

| Offset | Size | Contents |
| --- | --- | --- |
| 0 | 22 | Sample name |
| 22 | 2 | Length in **words** (big-endian) |
| 24 | 1 | Finetune. Low 4 bits, a signed value from -8 to 7 |
| 25 | 1 | Default volume, 0 to 64 |
| 26 | 2 | Loop start in words (big-endian) |
| 28 | 2 | Loop length in words (big-endian) |

### The traps

The format is simple, but it has a few traps that catch almost everyone. Read these before you start.

- **Everything is big-endian.** The Amiga's 68000 CPU stored the high byte first. Your Mac or PC stores the low byte first. You cannot `fread` a 16-bit value directly into a `uint16_t`. Build it from two bytes yourself.
- **Lengths are in words.** A word is 2 bytes. Multiply length, loop start and loop length by 2 to get bytes.
- **The number of patterns is not stored anywhere.** You have to work it out: it is the highest pattern number in the order list, plus one. Scan all 128 entries, not just the first `song length` of them. Unused entries sometimes point at patterns that still exist in the file.
- **The signature tells you the channel count.** `M.K.`, `M!K!`, `FLT4` and `4CHN` mean 4 channels. `6CHN` means 6 and `8CHN` means 8. M!K! is what ProTracker writes when a song has more than 64 patterns. FLT8 is also 8 channels, but it stores its patterns differently, so reject it for now. Anything else is probably an old 15-sample Soundtracker file with a different layout. Reject those for now.
- **Sample data is signed.** Each byte is an `int8_t` from -128 to 127.
- **A loop length of 1 word (2 bytes) means no loop.** ProTracker uses it as "off". Treat anything at 2 bytes or below as a one-shot sample.
- **Files lie.** Some files are truncated and claim samples longer than the data that remains. Clamp each sample's length to what is actually left in the file.

### Data structures

Here is a reasonable shape for the loaded song. Feel free to change it, but keep notes decoded into a struct instead of raw bytes. You will thank yourself when writing effects.

```c
typedef struct {
    char     name[23];     // 22 chars + terminator
    uint32_t length;       // in bytes
    int8_t   finetune;     // -8..7
    uint8_t  volume;       // 0..64
    uint32_t loop_start;   // in bytes
    uint32_t loop_length;  // in bytes, <= 2 means no loop
    int8_t  *data;
} Sample;

typedef struct {
    uint8_t  sample;       // 0 = none, 1..31
    uint16_t period;       // 0 = none
    uint8_t  effect;       // 0x0..0xF
    uint8_t  param;        // 0x00..0xFF
} Note;

typedef struct {
    char     title[21];
    Sample   samples[31];
    int      song_length;
    uint8_t  orders[128];
    int      num_patterns;
    int      num_channels;
    Note    *notes;        // num_patterns * 64 * num_channels
} Mod;
```

With a flat `notes` array, the cell for a given pattern, row and channel is at index `(pattern * 64 + row) * num_channels + channel`. Write a small helper for this. You will call it constantly.

The simplest way to load is to read the whole file into a buffer first and then parse from memory. This is boring code, so here it is:

```c
static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(n);
    if (buf && fread(buf, 1, n, f) != (size_t)n) { free(buf); buf = NULL; }
    fclose(f);
    *size = (size_t)n;
    return buf;
}
```

### Your task: write `mod_load`

Parse the header, the sample headers, the order list and the signature. Count the patterns. Skip over the pattern data for now (you will decode it in the next section), then copy each sample's data into its own buffer.

In outline:

```
read file into buf
copy title
for each of 31 sample headers:
    read name, length*2, finetune, volume, loop_start*2, loop_length*2
read song_length and the 128 orders
num_patterns = max(orders) + 1
channels = from signature, or fail
pattern_bytes = num_patterns * 64 * channels * 4
sample data starts at 1084 + pattern_bytes
for each sample:
    clamp length to remaining bytes
    allocate + copy, advance
```

**Hint:** For the finetune, take the low nibble and sign-extend it from 4 bits. If you did the LC-3 tutorial, this is the same `sign_extend` you already wrote. Values 8 to 15 become -8 to -1.

**Checkpoint:** Print the song title, the 31 sample names with their lengths, the channel count, the number of patterns and the order list. Sample names are where composers left messages, so you will often see greetings and credits there. If a sample length is wildly larger than the file, you probably forgot it is big-endian.

> **Shortcut:** Keep the file buffer alive and point each `Sample.data` straight into it instead of copying. That is one less allocation per sample, and `mod_free` just frees the buffer. You will want real copies again in Part 2, when the editor changes sample data.

> **Shortcut:** If you only load `M.K.` files for now, you can hard-code 4 channels and add the other signatures later.

The answer is under **Loader** in the cheat sheet.

## Decoding a note

Every cell in a pattern is exactly 4 bytes. Those 4 bytes hold a sample number (up to 31, so 5 bits), a period (up to 856, so 12 bits), an effect (4 bits) and an effect parameter (8 bits). That adds up to 29 bits, packed into 32 in a way that only makes sense historically.

The original Soundtracker only had 15 samples, which fit in 4 bits. When Mahoney & Kaktus raised the limit to 31 in NoiseTracker, the sample number needed one more bit. The only free bits were at the very top of the cell, so the new high bits of the sample number were squeezed in there, far away from the low bits.

Here is how the fields are laid out, in file order:

&#91;embedded content: MOD note cell · 4 bytes, 6 fields\]

Same colour means same field. The period is contiguous, but the sample number is split in two.

### Worked example

Take the 4 bytes `11 AC 3C 40`. Write them out in binary and split them on the field boundaries from the diagram above:

```
byte 0      byte 1      byte 2      byte 3
0001 0001   1010 1100   0011 1100   0100 0000
^^^^ ^^^^   ^^^^^^^^^   ^^^^ ^^^^   ^^^^^^^^^
|    |      |           |    |      param = 0x40
|    |      |           |    effect = 0xC
|    |      |           sample low = 0x3
|    period high = 0x1  period low = 0xAC
sample high = 0x1
```

Putting the pieces back together:

- sample = high nibble `0x1`, low nibble `0x3` → `0x13` = 19
- period = `0x1` and `0xAC` → `0x1AC` = 428, which the period table says is `C-2`
- effect = `0xC` (set volume), param = `0x40` = 64

In a tracker this cell reads `C-2 13 C40`: play sample 19 at C-2, at full volume.

Notice that the high and low halves of the sample number are in **byte 0** and **byte 2**. That is the part people get wrong. The period and effect are each in one tidy place.

### Your task: decode the patterns

Go back to your loader. Instead of skipping the pattern data, walk it 4 bytes at a time and decode each cell into a `Note`. You need only shifts, masks and ORs. Use the worked example above as your test case.

**Hint:** Write each field as one expression. For the sample number: keep the top nibble of byte 0 where it is, and move the top nibble of byte 2 down into the low nibble.

### Your task: print a pattern

Before making any sound, make your player able to show you what it is about to play. This is the most useful debugging tool you will build, so do not skip it.

Write a function that prints one pattern as text, in the same format as the example in *What is a tracker?* To turn a period into a note name, search the `PERIODS` table for it. Its index divided by 12 gives the octave (add 1), and the index modulo 12 gives the note within the octave. Use `---` for an empty note and `???` for a period that is not in the table.

```c
static const char *NOTE_NAMES[12] = {
    "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"
};
```

**Checkpoint:** Open the same file in MilkyTracker or OpenMPT and print the first pattern in the order list. Your output should match what the tracker shows, cell for cell. If notes look right but sample numbers are off by 16, check the sample nibbles again.

> **Speedup:** Searching the period table every time you print a note or run an arpeggio is wasteful. While loading, look up each period once and store its table index (or -1) in the `Note`. The printer and the arpeggio effect then read it directly.

> **Shortcut:** If note names feel like a detour, print the raw period in hex first (`1AC` instead of `C-2`). It is enough to spot decoding bugs, and you can add names later.

## Playing a sample

You have the data. Now let's make a noise. In this section you will play a single sample at a single pitch and write the result to a WAV file. No timing, no patterns, no SDL. Just one sample turned into sound you can hear.

### Digital audio in one paragraph

Sound is a pressure wave. A digital recording measures that wave at regular intervals and stores each measurement as a number. The number of measurements per second is the **sample rate**. Your sound card takes a stream of numbers at a fixed rate (we will use 48,000 per second) and turns them back into a voltage for the speaker. To produce sound, all you ever do is hand it the right numbers, fast enough.

> **Note:** "Sample" means two things in this guide. A *sample* in tracker language is an instrument recording. A *sample* in audio language is one measurement. To keep them apart, we will call the second one a **frame** when it covers both stereo channels.

### Resampling

Here is the core problem. Your output runs at 48,000 frames per second. A sample playing at period 428 needs to be read at 3546895 / 428 ≈ 8287 bytes per second. Those rates do not match, so for each output frame you have to decide which byte of the sample to use.

The answer is to keep a **position** in the sample that moves forward by a fractional **step** each output frame:

```latex
\text{step} = \frac{3546895 / \text{period}}{\text{output rate}}
```

At period 428 and 48 kHz, the step is about 0.1727. Each output frame, you add 0.1727 to the position and read the byte at the whole-number part of it. The same byte gets read about six times in a row before the position moves on. Higher notes have smaller periods and larger steps, so they move through the sample faster.

Reading the byte at the whole-number part is called **nearest-neighbour** resampling. It is what Paula effectively did, and it gives MODs their slightly crunchy sound. Later you can try linear interpolation (blend the two neighbouring bytes by the fractional part) and hear the difference.

### Fixed point

You could store the position as a `double`. That works fine on a modern machine. But trackers, demos and old hardware all use **fixed point**, and it is worth learning here because you will use it again in the demo.

The idea: store a fractional number as an integer, with an agreed number of bits after the binary point. With 32 fraction bits in a `uint64_t`, the value 1.0 is `1ull << 32`, the whole part is `pos >> 32`, and the fractional part is `pos & 0xFFFFFFFF`. Adding two of these is just integer addition.

> **Note:** Many tutorials use 16.16 fixed point in a `uint32_t`. That does not work here. A MOD sample can be up to 131,070 bytes long, which does not fit in 16 integer bits. Use a 64-bit position.

### Loops

When the position runs off the end of the sample, one of two things happens:

- If the sample **loops** (loop length greater than 2 bytes), it plays through once, then repeats the region from `loop_start` to `loop_start + loop_length` forever.
- If it does **not loop**, the channel goes silent at the end.

There is one ProTracker quirk in how far that first pass goes. If the loop starts after byte 0, playback runs to the loop end and wraps there, so anything after the loop end is never heard. If the loop starts at byte 0, the **whole** sample plays once, and only then does the loop take over. Keep an `in_loop` flag on the channel so you know which pass you are on.

This is how a short recording of a sustained instrument can play for as long as the note is held.

### The channel

Each channel needs to remember what it is playing. A good starting point:

```c
typedef struct {
    const Sample *sample;   // the instrument, kept even while silent
    int      active;        // 0 = not producing sound
    int      in_loop;       // 0 on the first pass through the sample
    uint64_t pos;           // 32.32 fixed point, in bytes
    uint64_t step;          // 32.32 fixed point
    uint16_t period;
    int      volume;        // 0..64
} Channel;
```

You will add more fields when you get to effects.

The heart of the player is a function that produces one output value from one channel and advances it. In pseudocode:

```
channel_next(ch):
    if not active: return 0
    i = ch.pos >> 32
    if sample loops:
        end = in_loop ? loop_end : (loop_start == 0 ? length : loop_end)
        if i >= end: move pos back into the loop, set in_loop, recompute i
    else if i >= length:
        active = 0, return 0
    value = sample.data[i] * ch.volume       // -8192..8128
    ch.pos += ch.step
    return value
```

### Writing a WAV file

A WAV file is a 44-byte header followed by raw 16-bit little-endian frames. Rendering to a file first means you can test your player without dealing with real-time audio, threads or SDL. It also lets you open the result in an audio editor and look at the waveform. This code is boring, so here it is in full:

```c
static void put16(FILE *f, uint16_t v) { fputc(v & 0xFF, f); fputc(v >> 8, f); }
static void put32(FILE *f, uint32_t v) { put16(f, v & 0xFFFF); put16(f, v >> 16); }

// frames: interleaved stereo int16, frame_count frames
int wav_write(const char *path, const int16_t *frames, uint32_t frame_count, int rate) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    uint32_t data_bytes = frame_count * 4;
    fwrite("RIFF", 1, 4, f); put32(f, 36 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); put32(f, 16);
    put16(f, 1);             // PCM
    put16(f, 2);             // stereo
    put32(f, rate);
    put32(f, rate * 4);      // bytes per second
    put16(f, 4);             // bytes per frame
    put16(f, 16);            // bits per sample
    fwrite("data", 1, 4, f); put32(f, data_bytes);
    for (uint32_t i = 0; i < frame_count * 2; i++) put16(f, (uint16_t)frames[i]);
    fclose(f);
    return 1;
}
```

### Your task: play one sample

Pick a sample from your MOD that has a decent length (a bass or a lead, not a drum). Set up one channel with that sample, period 428 and volume 64. Generate 2 seconds of output at 48 kHz, put the same value in the left and right slot of each frame, and write it to a WAV.

**Hint:** `sample.data[i] * 64` tops out at about 8192, which is quiet in a 16-bit range of ±32767. Multiply by 2 or 4 for now so you can hear it clearly. We will handle levels properly when mixing.

**Checkpoint:** Play the WAV. You should hear the instrument from the song, at roughly the right pitch. Try period 214 and you should hear the same thing one octave higher. A looping sample should sustain for the full 2 seconds. A drum should play once and stop.

> **Shortcut:** Start with a `double` for the position and step, and switch to fixed point once the song plays. Nothing else in the guide depends on the choice.

> **Speedup:** The step depends only on the period and finetune, and a period never exceeds 4095. Precompute a step table once per output rate, or cache the last period on the channel and recompute only when it changes. Either way the `pow` and the divide leave the hot path.

> **Speedup:** The loop check runs on every frame. A faster mixer works out how many frames remain before the position reaches the end, roughly `(end - pos + step - 1) / step` in fixed point, mixes that many frames with no checks at all, then handles the wrap. Another classic trick is to pad each sample at load time with an extra copy of its loop, so reading a few frames past the end is always safe.

The answer is under **Channel** in the cheat sheet.

## Timing: ticks and rows

You can play one note. Now you need to play the right notes at the right time. This is the job of the **sequencer**, and the key to it is a unit smaller than a row: the **tick**.

### Ticks

Early trackers ran their playback code once per screen refresh, 50 times a second on a PAL Amiga. Each of those updates is a tick. ProTracker later drove the player from a hardware timer (one of the Amiga's CIA chips), which let a song change the tick rate. Everything that changes over time in a MOD (new rows, volume slides, vibrato) happens on a tick.

Two numbers control the timing:

- **Speed**: how many ticks make up one row. Default 6.
- **Tempo** (BPM): how long a tick lasts. Default 125, which gives exactly 50 ticks per second.

The length of one tick in seconds is 2.5 / tempo. So at 48 kHz:

```latex
\text{frames per tick} = \frac{\text{output rate} \times 2.5}{\text{tempo}} = \frac{48000 \times 2.5}{125} = 960
```

At the default speed of 6, one row lasts 6 × 960 = 5760 frames, or 0.12 seconds. A full 64-row pattern lasts 7.68 seconds.

Why have both? Speed changes how many ticks a row lasts, which is a coarse control. Tempo changes the length of every tick, which is a fine control. Effects also run per tick, so speed also controls how many steps a slide takes per row.

> **Note:** "BPM" in a MOD is not really beats per minute. It only matches musical BPM at speed 6 with a beat every 4 rows. Think of it as "tick rate" and you will avoid confusion.

### What happens on each tick

**Tick 0** is the start of a row. The sequencer reads the next row from the current pattern and, for each channel, applies the cell:

- If the cell has a **sample number**, that sample becomes the channel's instrument and the channel volume resets to the sample's default volume.
- If the cell has a **period**, the channel plays its current instrument at that period from the start: position goes back to 0.
- Otherwise nothing changes. The note that was playing keeps playing.

**Ticks 1 to speed - 1** don't read anything new. For now they do nothing. Once you implement effects, this is where slides and vibrato do their work.

After the last tick of a row, move to the next row. After row 63, move to the next entry in the order list. When you run past `song_length`, the song is over.

> **Note:** A cell with a period but no sample number replays the channel's previous instrument. A cell with a sample number but no period resets the volume without restarting the sound. Both are common, so handle both.

### The player

The sequencer and the audio generation need to interleave. Audio is produced in frames, and a tick happens every 960 or so frames. So the player alternates: run a tick, generate frames until the next tick is due, run a tick, and so on.

Add a player struct alongside your channels:

```c
typedef struct {
    const Mod *mod;
    int      rate;              // output sample rate
    Channel  ch[8];
    int      order, row, tick;
    int      speed, tempo;
    int      frames_left;       // frames until the next tick
    int      ended;
} Player;
```

Then `player_render` becomes a loop like this:

```
player_render(p, out, frames):
    while frames > 0:
        if p.frames_left == 0:
            player_tick(p)
            p.frames_left = rate * 2.5 / tempo
        n = min(frames, p.frames_left)
        mix n frames from all channels into out
        out += n * 2; frames -= n; p.frames_left -= n

player_tick(p):
    if tick == 0: process_row(p)
    else:         per-tick effects (later)
    tick += 1
    if tick >= speed:
        tick = 0
        advance row (and order, and maybe end)
```

The key property is that **the caller decides how many frames it wants.** A WAV writer can ask for 4096 at a time, an SDL callback asks for whatever it needs, and the music sounds the same either way. The player keeps track of where it is between calls.

> **Note:** At most tempos `rate * 2.5 / tempo` is not a whole number. At tempo 137 it is 875.9. Rounding each tick is fine for now. If you want exact timing, keep the remainder and carry it into the next tick.

### Your task: render the whole song

Implement `player_init`, `player_tick`, `process_row` and `player_render`. Ignore effects for now, except for one: effect `F` with a parameter below `0x20` sets the speed, and with a parameter of `0x20` or above sets the tempo. Almost every song sets one of these on its first row, and without it the song plays at the wrong pace.

Then write a `main` that loads a MOD, renders it in chunks until `ended` is set and writes the result to a WAV. For mixing, just add the channels together and put the same value in left and right. Clamp to the `int16_t` range.

**Hint:** Some songs never end because they jump back to an earlier position with effect `B`. Since you are not handling effects yet that cannot happen, but it will soon. Cap the render at 10 minutes.

**Checkpoint:** Play the WAV. You should hear the song, recognizably, at the right speed. It will sound wrong in places: notes that should slide will jump, volumes will be flat and some sections may play too long. That is all effects, and we will get there. If the whole thing sounds like noise, print the pattern as you go and compare it with the tracker.

> **Shortcut:** Many songs set speed and tempo on the first row and never change them. If yours does, you can skip `Fxx` at first and hard-code the values the tracker shows. Add it back before you start on effects.

> **Note:** ProTracker's own timer runs at `709379 / (1773447 / tempo + 1)` ticks per second, with integer division. At tempo 125 that is 49.998 instead of exactly 50. Nobody can hear the difference, so the 2.5 / tempo formula is fine.

The answer is under **Sequencer** in the cheat sheet.

## Mixing and real-time output

Your song plays, but in mono and probably either too quiet or clipping. In this section you will mix the channels properly into stereo and then play the result live through SDL3.

### Mixing is addition

Mixing audio is just adding the values from each channel together. Two sounds played at once produce a pressure wave that is the sum of both waves. The only real question is how to keep the sum inside the 16-bit range.

Each channel produces at most 128 × 64 = 8192 in magnitude. Four channels added together reach 32768, which is just past the `int16_t` limit. In practice the channels rarely all peak at the same moment, so you can afford some gain and clamp the rare peaks. Do the sum in an `int32_t`, scale it, then clamp to -32768..32767 before storing it.

### Amiga panning

Remember that Paula sent two channels to each speaker. The arrangement was **left, right, right, left**: channels 1 and 4 on the left, channels 2 and 3 on the right. For 6- and 8-channel files, the same pattern repeats.

This is part of the MOD sound, and composers relied on it. But hard-panned channels sound strange on headphones, where each ear hears only half the band. Most players blend a little of each side into the other. A 25% to 30% blend sounds natural and keeps the stereo effect:

```
left_out  = left_sum  * 0.75 + right_sum * 0.25
right_out = right_sum * 0.75 + left_sum  * 0.25
```

Make the blend a setting so you can compare.

### Your task: stereo mixing

Replace the mono mix in `player_render` with a stereo mix. Sum each channel into a left or right accumulator depending on its position, apply the blend, scale and clamp. For files with more than 4 channels, reduce the gain so the extra channels don't clip constantly.

**Checkpoint:** Render to WAV again. The song should sound wider, and roughly as loud as other music you play at the same volume.

> **Speedup:** Swap the loops. Instead of visiting every channel for every frame, run each channel through the whole chunk into an `int32_t` accumulator buffer, then convert the buffer to `int16_t` in one pass. Inactive, muted and silent channels can then be skipped entirely, and the per-channel setup (sample pointer, step, pan side) happens once per chunk instead of once per frame.

> **Shortcut:** Hard panning with no blend is just two sums. It sounds odd on headphones, but it is authentic and it is one less thing to get right.

### Real-time output with SDL3

Playing through the speakers is mostly platform plumbing, so here is the code in full. The important idea is the **callback**: SDL calls your function on its own audio thread whenever it needs more data, and you fill it by calling `player_render`. This is exactly why the player was designed to produce any number of frames on demand.

```c
#include <SDL3/SDL.h>

static void SDLCALL audio_callback(void *userdata, SDL_AudioStream *stream,
                                   int additional_bytes, int total_bytes) {
    (void)total_bytes;
    Player *p = userdata;
    int16_t buf[1024 * 2];
    int frames = additional_bytes / 4;          // 4 bytes per stereo frame
    while (frames > 0) {
        int n = frames < 1024 ? frames : 1024;
        player_render(p, buf, n);
        SDL_PutAudioStreamData(stream, buf, n * 4);
        frames -= n;
    }
}

int play_sdl(Player *p) {
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 0;
    }
    SDL_AudioSpec spec = { .format = SDL_AUDIO_S16, .channels = 2, .freq = p->rate };
    SDL_AudioStream *stream = SDL_OpenAudioDeviceStream(
        SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_callback, p);
    if (!stream) {
        fprintf(stderr, "SDL_OpenAudioDeviceStream: %s\n", SDL_GetError());
        SDL_Quit();
        return 0;
    }
    SDL_ResumeAudioStreamDevice(stream);         // devices start paused

    int done = 0;
    while (!done) {
        SDL_Delay(100);
        SDL_LockAudioStream(stream);             // the callback holds this lock
        done = p->ended;
        SDL_UnlockAudioStream(stream);
    }

    SDL_DestroyAudioStream(stream);
    SDL_Quit();
    return 1;
}
```

Build with:

```
cc -O2 -Wall -std=c11 mod.c wav.c main.c $(pkg-config --cflags --libs sdl3) -o modplay
```

> **Note:** The callback runs on a different thread from `main`. Anything both threads touch must be protected. SDL holds the stream's lock while it runs your callback, so locking the stream from the main thread is enough. Remember this in Part 2, when the editor starts changing the song while it plays.

> **Note:** Never do slow work inside the callback: no `printf`, no `malloc`, no file access. If the callback is late, the sound card runs out of data and you hear clicks and dropouts. This rule matters even more in the demo, where you also have graphics competing for time.

**Checkpoint:** `./modplay song.mod` plays the song live and exits at the end. Add a flag (for example `-o out.wav`) to render to a file instead. You will want both modes while debugging effects.

> **Shortcut:** You don't have to use a callback. Pass `NULL` as the callback to `SDL_OpenAudioDeviceStream`, then in your main loop check `SDL_GetAudioStreamQueued(stream)`, which returns the bytes still waiting, and call `SDL_PutAudioStreamData` with more frames whenever it drops below a threshold such as 8192 bytes. Only the main thread touches the player, so you need no locks. The cost is a little extra latency. A music player won't notice it, but a demo or an editor with live note entry will, which is why the guide uses the callback.

## Implementing effects

Effects are where a MOD gets its character: slides, vibrato, arpeggios, echoes faked with volume tricks. Without them your player plays the right notes but none of the expression. There are 16 effect numbers, `0` to `F`, and effect `E` has 16 sub-effects of its own. That sounds like a lot, but just like LC-3 instructions, they are built from a handful of ideas, and several are rare enough to skip. I will walk through two of them in detail. The rest reuse what you learn here.

### Two kinds of effects

Every effect fits one of two shapes:

- **Row effects** happen once, on tick 0. Set the volume, jump to another position, change the speed. They act when the row is read.
- **Tick effects** happen on every tick *except* tick 0. Volume slides, pitch slides and vibrato. They act between rows, which is why speed matters: at speed 6, a slide gets 5 steps per row.

That "except tick 0" is important and easy to get wrong. ProTracker does not slide on tick 0, so a volume slide of `A01` at speed 6 changes the volume by 5 per row, not 6.

So your player needs two places where effects run. In `process_row` (tick 0), save each channel's effect and parameter in the channel and handle the row effects. In `player_tick` for ticks 1 and up, loop over the channels and handle the tick effects using the saved values.

### The parameter

The parameter byte is used in two ways. Some effects treat it as one number from 0 to 255 (`C40` = volume 64). Others split it into two nibbles, called `x` (high) and `y` (low): `A0F` means x = 0, y = 15. Extend the decoding you already have:

```c
uint8_t x = param >> 4, y = param & 0x0F;
```

### Base period and output period

Before you write any pitch effect, separate two ideas that are easy to merge by accident:

- The **base period** is the note the channel is playing. Slides change it permanently.
- The **output period** is what you actually play this tick. Vibrato and arpeggio wobble around the base period without changing it.

If vibrato modified the base period directly, every wobble would drift the note further off pitch. So keep `period` as the base, and compute the step from an output period at the end of each tick. Most ticks they are the same value.

### Worked example 1: volume

Let's start with the simplest pair: `Cxx` (set volume) and `Axy` (volume slide).

**Cxx** is a row effect. On tick 0, set the channel's volume to the parameter. Composers sometimes write values above 64 by mistake, so clamp it:

```c
case 0xC:
    ch->volume = param > 64 ? 64 : param;
    break;
```

Notice the order of operations. A cell like `C-2 01 C20` contains both a sample number and an effect. The sample number resets the volume to sample 1's default, and then `C20` overrides it with 32. So in `process_row`, handle the note and sample first and the effect after.

**Axy** is a tick effect. The specification:

> On each tick except the first, if x is non-zero, increase the volume by x. Otherwise decrease it by y. The volume stays within 0 to 64.

That translates directly. In the per-tick switch:

```c
case 0xA:
    if (x) ch->volume += x;
    else   ch->volume -= y;
    if (ch->volume > 64) ch->volume = 64;
    if (ch->volume < 0)  ch->volume = 0;
    break;
```

If both nibbles are set, `x` wins. Some songs rely on that, so keep it.

To summarise what this example taught:

- Row effects go in `process_row`, after the note is triggered.
- Tick effects go in the per-tick switch and skip tick 0.
- Split the parameter into nibbles when the effect needs two values.
- Clamp to the valid range. Files contain mistakes.

### Worked example 2: tone portamento

`3xx` is the slide that makes a note glide smoothly into the next one. It introduces two ideas the volume effects did not: an effect that **changes how the note is triggered**, and **effect memory**.

The specification:

> Slide the period toward the period of the note in this cell, by xx units per tick. The note is not retriggered. If xx is 0, use the speed from the last tone portamento on this channel.

First, the trigger. Normally a period in a cell restarts the sample at that pitch. With `3xx`, the period instead becomes a **target**, and the channel keeps playing what it was playing. So `process_row` needs a special case before it triggers anything:

```
if effect is 3 (or 5, which we'll meet later):
    if cell has a period: ch.porta_target = period
    if param != 0:        ch.porta_speed  = param
    do NOT reset position or change ch.period
else if cell has a period:
    trigger normally
```

Second, the memory. A composer writes `340` once to set a speed, then `300` on the following rows to keep sliding at the same rate. If a parameter of 0 meant "slide by 0", those rows would do nothing. Many effects work this way, so get used to adding a `_speed` or `_mem` field to the channel whenever a spec says "if the parameter is 0, use the previous value".

The tick part moves the base period toward the target without overshooting:

```c
case 0x3:
    if (ch->period < ch->porta_target) {
        ch->period += ch->porta_speed;
        if (ch->period > ch->porta_target) ch->period = ch->porta_target;
    } else if (ch->period > ch->porta_target) {
        ch->period -= ch->porta_speed;
        if (ch->period < ch->porta_target) ch->period = ch->porta_target;
    }
    break;
```

When you hear it working, it is satisfying. Bass lines and leads that sounded choppy will suddenly glide.

### Your task: the remaining effects

Here is the specification for the rest. Implement them roughly in this order. The first few fix the most audible problems.

| Effect | Name | When | What it does |
| --- | --- | --- | --- |
| `Dxy` | Pattern break | Row | After this row, go to the next order entry and start at row `x * 10 + y`. The parameter is decimal, not hex. |
| `Bxx` | Position jump | Row | After this row, go to order entry `xx`, row 0. |
| `1xx` | Portamento up | Tick | Subtract `xx` from the base period. Minimum 113. |
| `2xx` | Portamento down | Tick | Add `xx` to the base period. Maximum 856. |
| `5xy` | Tone porta + volume slide | Both | Continue the tone portamento with its remembered speed, and do `Axy` with this parameter. |
| `4xy` | Vibrato | Tick | Wobble the output period. `x` is speed, `y` is depth. Either one set to 0 keeps its previous value. |
| `6xy` | Vibrato + volume slide | Both | Continue vibrato with its remembered speed and depth, and do `Axy` with this parameter. |
| `0xy` | Arpeggio | Every tick | Cycle the output period through the base note, +x semitones and +y semitones, one per tick. `000` means no effect. |
| `9xx` | Sample offset | Row | When the note triggers, start at byte `xx * 256` instead of 0. `00` reuses the previous offset. Past the end, a looped sample plays its loop and a one-shot goes silent. |
| `7xy` | Tremolo | Tick | Like vibrato, but wobbling the volume instead of the period. |
| `E1x` / `E2x` | Fine porta up / down | Row | Slide the period by `x` once, on tick 0 only. |
| `EAx` / `EBx` | Fine volume up / down | Row | Change the volume by `x` once, on tick 0 only. |
| `ECx` | Note cut | Tick | On tick `x`, set the volume to 0. |
| `EDx` | Note delay | Tick | Do not trigger this cell's note until tick `x`. |
| `E9x` | Retrigger | Tick | Restart the sample every `x` ticks. |
| `E6x` | Pattern loop | Row | `E60` marks a loop start. `E6x` jumps back to it `x` times. |
| `EEx` | Pattern delay | Row | Repeat this row `x` extra times, without retriggering notes. Tick effects keep running, even on tick 0 of each repeat. |
| `8xx` | (unused) |  | ProTracker ignores it. Some later players use it for panning. Ignore it. |

A few notes to save you some pain:

- **Jumps are deferred.** `B` and `D` do not move the position immediately. Set a flag and apply it when the row ends. If a row has both, `B` picks the order entry and `D` picks the row within it.
- **Vibrato uses a sine table.** ProTracker does not call `sin()`. It uses a 32-entry table for half a wave and flips the sign for the other half. The position runs from 0 to 63 and advances by the speed each tick. The table is boring data, so copy it:

```c
static const uint8_t SINE[32] = {
      0,  24,  49,  74,  97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120,  97,  74,  49,  24,
};
```

- **Vibrato depth.** The amount added to the period is `SINE[pos & 31] * depth >> 7`, negated when `pos & 32` is set. For tremolo, shift by 6 instead of 7 and apply the result to the volume.
- **Arpeggio needs semitones.** Find the base period in the `PERIODS` table and step `x` or `y` entries further along. If the period is not in the table, find the closest entry.
- **Reset the vibrato position** when a new note triggers, so each note starts its wobble at the same point.
- **Finetune** comes last. A sample's finetune shifts its pitch in steps of 1/8 of a semitone. The simplest correct-enough approach is to multiply the playback rate by 2^(finetune / 96) when you compute the step.

**More ProTracker details** from the replayer source. You can skip all of these on a first pass:

- **`F00` stops the song** in ProTracker 2.3. Some later players ignore it instead.
- **`Axy` with both nibbles set** slides up by `x` and ignores `y`. Some other trackers do nothing in that case. Follow ProTracker.
- **`EDx`** in ProTracker delays only the restart of the sample. The new period and the sample's default volume apply on tick 0. Delaying the whole cell, as the cheat sheet does, is a close approximation.
- **`EEx`**: during the repeats, tick 0 also runs the tick effects, so slides continue without a pause.
- **`E9x`** also retriggers on tick 0, unless the cell already started a note.
- **Not covered:** `E0x` (the Amiga's low-pass filter switch), `E3x` (glissando), `E4x` and `E7x` (vibrato and tremolo waveforms), `E5x` (set finetune), `E8x` (unused by ProTracker, mostly a sync marker for demos) and `EFx` (invert loop, which rewrites sample data while playing). They are rare enough to ignore for now.

**Hint:** Debug each effect by finding it in a real song. Print the pattern, find a row that uses the effect, and listen to just that part. You can also mute channels to isolate one instrument. Add a mute mask to your player now. You will use it in Part 2 as well.

**Checkpoint:** Your player should now sound close to MilkyTracker or OpenMPT on most songs. Render the same song in both, line the WAVs up in an audio editor and look for places where they differ.

> **Shortcut:** `C`, `F`, `D`, `B`, `A` and `3` fix most of what sounds wrong in a typical song. Get those six working first and listening becomes pleasant, then add the rest at your own pace.

> **Speedup:** There is nothing worth optimising here. Effects run once per tick per channel, about 200 times a second for a 4-channel song, while the mixer runs 48,000 times a second. Keep the effect code simple and readable.

The answers are under **Effects** in the cheat sheet.

## Debugging

Audio bugs are hard to debug by ear. "It sounds a bit off" tells you almost nothing. The trick is to turn sound back into something you can read or see.

- **Print as you play.** Add a flag that prints each row as it is processed, in the same format as your pattern printer, along with the order position. When something sounds wrong, you can see exactly which row and which effect was playing.
- **Compare with a reference.** Render the same song in OpenMPT (*File → Stream Export*) and in your player. Load both WAVs into [Audacity](https://www.audacityteam.org) on separate tracks. Where the waveforms diverge, you have a bug. Zoom in and read off the time, then work out the row from your tempo.
- **Solo a channel.** Most bugs live in one channel. A mute mask that lets you play only channel 3 cuts the problem down quickly.
- **Test songs.** Some composers made modules specifically to test players. Search The Mod Archive for "protracker test" or "effect test". They exercise one effect at a time.

> **Shortcut:** You don't need a GUI to make a reference file. `openmpt123`, the command-line player that comes with libopenmpt, renders a module to an audio file next to it with `openmpt123 --render song.mod`. A short script that loads both WAVs and prints where they first diverge is faster than comparing by eye. Expect small differences everywhere, because no two players resample the same way. Look for places where the shapes differ.

When something is wrong, these are the usual suspects, roughly in order of how often they bite:

| Symptom | Likely cause |
| --- | --- |
| Garbage or a crash when loading | Forgot big-endian, or forgot to multiply lengths by 2 |
| Sample data is shifted or every sample sounds wrong | Wrong pattern count. Scan all 128 orders, not just `song_length`. |
| Wrong instruments play | Sample number nibbles mixed up between byte 0 and byte 2 |
| Loud harsh noise | Treating sample data as unsigned |
| Song plays far too fast or slow | Not handling `Fxx`, or the frames-per-tick formula is wrong |
| Slides overshoot or go too far | Running tick effects on tick 0 as well |
| Song skips sections or repeats wrongly | `Dxy` parameter read as hex instead of decimal, or jumps applied mid-row |
| Vibrato slowly drifts out of tune | Vibrato changing the base period instead of the output period |
| Clicks during playback | Slow work in the audio callback, or a buffer too small |

If you followed the LC-3 tutorial, the advice there applies here too: when you find a discrepancy, reread the spec for that one effect and check your code against it line by line. It is almost always a small misreading.

## Cheat sheet

Working answers for every task, in the order the tasks appear. Try each task first. Yours does not need to match these. If it plays the song correctly, it is correct.

These need `<stdio.h>`, `<stdlib.h>`, `<string.h>`, `<stdint.h>` and `<math.h>`. On Linux, link with `-lm`.

### Loader

```c
static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

static const Note *mod_note(const Mod *m, int pattern, int row, int ch) {
    return &m->notes[(pattern * 64 + row) * m->num_channels + ch];
}

int mod_load(Mod *mod, const char *path) {
    size_t size;
    uint8_t *buf = read_file(path, &size);
    if (!buf) return 0;
    memset(mod, 0, sizeof *mod);
    if (size < 1084) goto fail;

    memcpy(mod->title, buf, 20);

    for (int i = 0; i < 31; i++) {
        const uint8_t *h = buf + 20 + i * 30;
        Sample *s = &mod->samples[i];
        memcpy(s->name, h, 22);
        s->length      = be16(h + 22) * 2;
        int ft         = h[24] & 0x0F;
        s->finetune    = ft > 7 ? ft - 16 : ft;          // 4-bit sign extend
        s->volume      = h[25] > 64 ? 64 : h[25];
        s->loop_start  = be16(h + 26) * 2;
        s->loop_length = be16(h + 28) * 2;
    }

    mod->song_length = buf[950];
    if (mod->song_length < 1 || mod->song_length > 128) goto fail;
    memcpy(mod->orders, buf + 952, 128);

    int highest = 0;
    for (int i = 0; i < 128; i++)                     // all 128, not song_length
        if (mod->orders[i] > highest) highest = mod->orders[i];
    mod->num_patterns = highest + 1;

    const char *sig = (const char *)buf + 1080;
    if      (!memcmp(sig, "M.K.", 4) || !memcmp(sig, "M!K!", 4) ||
             !memcmp(sig, "FLT4", 4) || !memcmp(sig, "4CHN", 4)) mod->num_channels = 4;
    else if (!memcmp(sig, "6CHN", 4))                             mod->num_channels = 6;
    else if (!memcmp(sig, "8CHN", 4))                             mod->num_channels = 8;
    else goto fail;                                   // 15-sample or unknown format

    size_t cells = (size_t)mod->num_patterns * 64 * mod->num_channels;
    if (1084 + cells * 4 > size) goto fail;
    mod->notes = malloc(cells * sizeof(Note));
    if (!mod->notes) goto fail;

    const uint8_t *p = buf + 1084;
    for (size_t i = 0; i < cells; i++, p += 4) {
        Note *n   = &mod->notes[i];
        n->sample = (p[0] & 0xF0) | (p[2] >> 4);
        n->period = ((p[0] & 0x0F) << 8) | p[1];
        n->effect = p[2] & 0x0F;
        n->param  = p[3];
    }

    size_t off = 1084 + cells * 4;
    for (int i = 0; i < 31; i++) {
        Sample *s = &mod->samples[i];
        size_t left = off < size ? size - off : 0;
        if (s->length > left) s->length = (uint32_t)left;   // truncated file
        if (s->loop_start >= s->length) s->loop_length = 0;
        else if (s->loop_start + s->loop_length > s->length)
            s->loop_length = s->length - s->loop_start;
        if (s->length) {
            s->data = malloc(s->length);
            if (!s->data) goto fail;
            memcpy(s->data, buf + off, s->length);
            off += s->length;
        }
    }

    free(buf);
    return 1;
fail:
    free(buf);
    mod_free(mod);
    return 0;
}

void mod_free(Mod *mod) {
    free(mod->notes);
    for (int i = 0; i < 31; i++) free(mod->samples[i].data);
    memset(mod, 0, sizeof *mod);
}
```

And the pattern printer:

```c
static int period_index(int period) {           // exact match, or -1
    for (int i = 0; i < 36; i++) if (PERIODS[i] == period) return i;
    return -1;
}

static void print_cell(const Note *n) {
    if (!n->period)                    printf("---");
    else {
        int i = period_index(n->period);
        if (i < 0) printf("???");
        else       printf("%s%d", NOTE_NAMES[i % 12], i / 12 + 1);
    }
    if (n->sample) printf(" %02X", n->sample); else printf(" --");
    if (n->effect || n->param) printf(" %X%02X", n->effect, n->param);
    else                       printf(" ---");
}

void print_pattern(const Mod *m, int pattern) {
    for (int row = 0; row < 64; row++) {
        printf("%02d ", row);
        for (int c = 0; c < m->num_channels; c++) {
            printf("| ");
            print_cell(mod_note(m, pattern, row, c));
            printf(" ");
        }
        printf("\n");
    }
}
```

### Channel

This uses one field that *Playing a sample* did not have yet: `out_volume`, which the effects section explains. Until then, keep `out_volume` equal to `volume`.

```c
static uint64_t step_for(int period, int finetune, int rate) {
    if (period <= 0) return 0;
    double hz = 3546895.0 / period;
    if (finetune) hz *= pow(2.0, finetune / 96.0);
    return (uint64_t)(hz / rate * 4294967296.0);     // 32.32 fixed point
}

static int channel_next(Channel *ch) {
    const Sample *s = ch->sample;
    if (!ch->active || !s || !s->data) return 0;
    uint32_t i = (uint32_t)(ch->pos >> 32);
    if (s->loop_length > 2) {
        uint32_t loop_end = s->loop_start + s->loop_length;
        // first pass: a loop starting at 0 plays the whole sample once
        uint32_t end = (ch->in_loop || s->loop_start) ? loop_end : s->length;
        if (i >= end) {
            ch->pos -= (uint64_t)(end - s->loop_start) << 32;
            ch->in_loop = 1;
            i = (uint32_t)(ch->pos >> 32);
            while (i >= loop_end) {                 // very high steps only
                ch->pos -= (uint64_t)s->loop_length << 32;
                i = (uint32_t)(ch->pos >> 32);
            }
        }
    } else if (i >= s->length) {
        ch->active = 0;
        return 0;
    }
    int v = s->data[i] * ch->out_volume;
    ch->pos += ch->step;
    return v;
}
```

For the single-sample test, set `ch.out_volume = 64` and `ch.step = step_for(428, 0, 48000)` by hand, then call `channel_next` 96,000 times.

### Sequencer

The no-effects version from *Timing: ticks and rows*. The full version, with effects, replaces `process_row` and `player_tick` under **Effects** below.

```c
void player_init(Player *p, const Mod *mod, int rate) {
    memset(p, 0, sizeof *p);
    p->mod = mod;
    p->rate = rate;
    p->speed = 6;
    p->tempo = 125;
    p->jump_order = p->break_row = p->loop_jump = -1;   // effects fields, add later
}

static void trigger(Player *p, Channel *ch, const Note *n) {
    if (n->sample >= 1 && n->sample <= 31) {
        ch->sample = &p->mod->samples[n->sample - 1];
        ch->volume = ch->sample->volume;
    }
    if (n->period && ch->sample) {
        ch->period = n->period;
        ch->pos = 0;
        ch->in_loop = 0;
        ch->active = 1;
    }
    ch->out_period = ch->period;
    ch->out_volume = ch->volume;
}

static void process_row(Player *p) {                     // no-effects version
    const Mod *m = p->mod;
    int pattern = m->orders[p->order];
    for (int c = 0; c < m->num_channels; c++) {
        const Note *n = mod_note(m, pattern, p->row, c);
        trigger(p, &p->ch[c], n);
        if (n->effect == 0xF) {
            if (n->param == 0)         p->ended = 1;      // F00 stops the song
            else if (n->param < 0x20)  p->speed = n->param;
            else                       p->tempo = n->param;
        }
    }
}

static void player_tick(Player *p) {                     // no-effects version
    if (p->ended) return;
    if (p->tick == 0) process_row(p);
    for (int c = 0; c < p->mod->num_channels; c++) {
        Channel *ch = &p->ch[c];
        ch->out_period = ch->period;
        ch->out_volume = ch->volume;
        ch->step = step_for(ch->out_period, ch->sample ? ch->sample->finetune : 0, p->rate);
    }
    if (++p->tick >= p->speed) {
        p->tick = 0;
        if (++p->row >= 64) {
            p->row = 0;
            if (++p->order >= p->mod->song_length) p->ended = 1;
        }
    }
}

void player_render(Player *p, int16_t *out, int frames) {
    while (frames > 0) {
        if (p->ended) { memset(out, 0, (size_t)frames * 4); return; }
        if (p->frames_left <= 0) {
            player_tick(p);
            p->frames_left = p->rate * 5 / (p->tempo * 2);   // rate * 2.5 / tempo
        }
        int n = frames < p->frames_left ? frames : p->frames_left;
        mix(p, out, n);
        out += n * 2;
        frames -= n;
        p->frames_left -= n;
    }
}
```

### Mixer

Amiga LRRL panning with a 25% blend. `mute` is a bitmask on the player: bit `c` set silences channel `c`.

```c
static int16_t clamp16(int32_t v) {
    return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v;
}

static void mix(Player *p, int16_t *out, int frames) {
    int nch = p->mod->num_channels;
    int gain = nch > 4 ? 1 : 2;
    for (int f = 0; f < frames; f++) {
        int32_t l = 0, r = 0;
        for (int c = 0; c < nch; c++) {
            int v = channel_next(&p->ch[c]);            // always advance, even if muted
            if (p->mute & (1u << c)) continue;
            if ((c & 3) == 0 || (c & 3) == 3) l += v;
            else                              r += v;
        }
        out[f * 2]     = clamp16((l * 3 + r) / 4 * gain);
        out[f * 2 + 1] = clamp16((r * 3 + l) / 4 * gain);
    }
}
```

### Effects

The final channel and player structs:

```c
typedef struct {
    const Sample *sample;
    int      active, in_loop;
    uint64_t pos, step;
    int      period, out_period;     // base and output (see "Base period and output period")
    int      volume, out_volume;
    uint8_t  effect, param;          // this row's effect
    int      porta_target, porta_speed;
    uint8_t  vib_pos, vib_speed, vib_depth;
    uint8_t  trem_pos, trem_speed, trem_depth;
    uint8_t  offset_mem;
    int      loop_row, loop_count;   // E6x
    Note     delayed;                // EDx
} Channel;

typedef struct {
    const Mod *mod;
    int      rate;
    Channel  ch[8];
    int      order, row, tick;
    int      speed, tempo;
    int      frames_left;
    int      ended;
    int      jump_order, break_row, loop_jump;   // -1 = none
    int      pattern_delay, repeat_row;
    uint32_t mute;
} Player;
```

Small helpers shared by several effects:

```c
static int clamp_i(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static int closest_index(int period) {
    int best = 0;
    for (int i = 1; i < 36; i++)
        if (abs(PERIODS[i] - period) < abs(PERIODS[best] - period)) best = i;
    return best;
}

static void vol_slide(Channel *ch, uint8_t prm) {
    int x = prm >> 4, y = prm & 0x0F;
    ch->volume = clamp_i(ch->volume + (x ? x : -y), 0, 64);
}

static void tone_porta(Channel *ch) {
    if (ch->period < ch->porta_target)
        ch->period = clamp_i(ch->period + ch->porta_speed, 0, ch->porta_target);
    else if (ch->period > ch->porta_target)
        ch->period = clamp_i(ch->period - ch->porta_speed, ch->porta_target, 4095);
}

static int wave(uint8_t pos, int depth, int shift) {
    int d = SINE[pos & 31] * depth >> shift;
    return (pos & 32) ? -d : d;
}
```

The row handler, run on tick 0:

```c
static void process_row(Player *p) {
    const Mod *m = p->mod;
    int pattern = m->orders[p->order];
    for (int c = 0; c < m->num_channels; c++) {
        Channel *ch = &p->ch[c];
        const Note *n = mod_note(m, pattern, p->row, c);
        uint8_t e = n->effect, prm = n->param, x = prm >> 4, y = prm & 0x0F;
        ch->effect = e;
        ch->param = prm;

        // 1. The note: delayed, sliding into, or triggered normally
        if (e == 0xE && x == 0xD && y) {
            ch->delayed = *n;                                    // EDx: trigger on tick y
        } else if (e == 0x3 || e == 0x5) {
            if (n->sample >= 1 && n->sample <= 31) {
                ch->sample = &m->samples[n->sample - 1];
                ch->volume = ch->sample->volume;
            }
            if (n->period) ch->porta_target = n->period;
            if (e == 0x3 && prm) ch->porta_speed = prm;
        } else {
            trigger(p, ch, n);
            if (n->period) {
                ch->vib_pos = ch->trem_pos = 0;
                if (e == 0x9 && ch->sample) {                    // 9xx: sample offset
                    const Sample *s = ch->sample;
                    int loops = s->loop_length > 2;
                    if (prm) ch->offset_mem = prm;
                    uint32_t off = ch->offset_mem * 256u;
                    uint32_t end = (loops && s->loop_start) ? s->loop_start + s->loop_length : s->length;
                    if (off < end)  ch->pos = (uint64_t)off << 32;
                    else if (loops) { ch->pos = (uint64_t)s->loop_start << 32; ch->in_loop = 1; }
                    else            ch->active = 0;
                }
            }
        }

        // 2. Row effects
        switch (e) {
        case 0x4: if (x) ch->vib_speed = x;  if (y) ch->vib_depth = y;  break;
        case 0x7: if (x) ch->trem_speed = x; if (y) ch->trem_depth = y; break;
        case 0xB: p->jump_order = prm; break;
        case 0xC: ch->volume = prm > 64 ? 64 : prm; break;
        case 0xD: p->break_row = x * 10 + y; if (p->break_row > 63) p->break_row = 0; break;
        case 0xE:
            switch (x) {
            case 0x1: ch->period = clamp_i(ch->period - y, 113, 856); break;
            case 0x2: ch->period = clamp_i(ch->period + y, 113, 856); break;
            case 0x6:
                if (y == 0) ch->loop_row = p->row;
                else if (ch->loop_count == 0) { ch->loop_count = y; p->loop_jump = ch->loop_row; }
                else if (--ch->loop_count)    { p->loop_jump = ch->loop_row; }
                break;
            case 0x9:                                            // retrigger on tick 0 too,
                if (y && !n->period && ch->sample) {             // unless a note just did
                    ch->pos = 0; ch->in_loop = 0; ch->active = 1;
                }
                break;
            case 0xA: ch->volume = clamp_i(ch->volume + y, 0, 64); break;
            case 0xB: ch->volume = clamp_i(ch->volume - y, 0, 64); break;
            case 0xC: if (y == 0) ch->volume = 0; break;
            case 0xE: if (!p->pattern_delay) p->pattern_delay = y; break;
            }
            break;
        case 0xF:
            if (prm == 0)         p->ended = 1;                  // F00 stops the song
            else if (prm < 0x20)  p->speed = prm;
            else                  p->tempo = prm;
            break;
        }
    }
}
```

The tick handler, run on ticks 1 and up. It changes only base values:

```c
static void tick_effects(Player *p) {
    for (int c = 0; c < p->mod->num_channels; c++) {
        Channel *ch = &p->ch[c];
        uint8_t prm = ch->param, x = prm >> 4, y = prm & 0x0F;
        switch (ch->effect) {
        case 0x1: ch->period = clamp_i(ch->period - prm, 113, 856); break;
        case 0x2: ch->period = clamp_i(ch->period + prm, 113, 856); break;
        case 0x3: tone_porta(ch); break;
        case 0x5: tone_porta(ch); vol_slide(ch, prm); break;
        case 0x6: vol_slide(ch, prm); break;
        case 0xA: vol_slide(ch, prm); break;
        case 0xE:
            if (x == 0x9 && y && p->tick % y == 0 && ch->sample) {
                ch->pos = 0; ch->in_loop = 0; ch->active = 1;
            }
            if (x == 0xC && p->tick == y) ch->volume = 0;
            if (x == 0xD && p->tick == y) trigger(p, ch, &ch->delayed);
            break;
        }
    }
}
```

The modulators, run on every tick after the base values are final. They only touch the output values:

```c
// fx = 1 on ticks where tick effects ran (any tick except a new row's tick 0)
static void modulate(Player *p, Channel *ch, int fx) {
    uint8_t prm = ch->param, x = prm >> 4, y = prm & 0x0F;
    ch->out_period = ch->period;
    ch->out_volume = ch->volume;
    if (ch->effect == 0x0 && prm) {                              // arpeggio
        int semis = p->tick % 3 == 1 ? x : p->tick % 3 == 2 ? y : 0;
        if (semis && ch->period)
            ch->out_period = PERIODS[clamp_i(closest_index(ch->period) + semis, 0, 35)];
    }
    if (!fx) return;
    if (ch->effect == 0x4 || ch->effect == 0x6) {                // vibrato
        ch->out_period = ch->period + wave(ch->vib_pos, ch->vib_depth, 7);
        ch->vib_pos = (ch->vib_pos + ch->vib_speed) & 63;
    }
    if (ch->effect == 0x7) {                                     // tremolo
        ch->out_volume = clamp_i(ch->volume + wave(ch->trem_pos, ch->trem_depth, 6), 0, 64);
        ch->trem_pos = (ch->trem_pos + ch->trem_speed) & 63;
    }
}
```

And the full tick, including deferred jumps and pattern delay:

```c
static void next_row(Player *p) {
    const Mod *m = p->mod;
    if (p->loop_jump >= 0) {                                     // E6x
        p->row = p->loop_jump;
        p->loop_jump = -1;
        return;
    }
    if (p->jump_order >= 0 || p->break_row >= 0) {               // Bxx / Dxy
        int order = p->jump_order >= 0 ? p->jump_order : p->order + 1;
        // A jump backwards usually means "loop the song". Treat it as the end.
        if (p->jump_order >= 0 && p->jump_order <= p->order) p->ended = 1;
        p->row = p->break_row >= 0 ? p->break_row : 0;
        p->order = order;
        p->jump_order = p->break_row = -1;
    } else if (++p->row >= 64) {
        p->row = 0;
        p->order++;
    }
    if (p->order >= m->song_length) p->ended = 1;
}

static void player_tick(Player *p) {
    if (p->ended) return;
    int new_row = (p->tick == 0 && !p->repeat_row);
    if (new_row) process_row(p);
    else         tick_effects(p);       // includes tick 0 of a delayed row
    for (int c = 0; c < p->mod->num_channels; c++) {
        Channel *ch = &p->ch[c];
        modulate(p, ch, !new_row);
        ch->step = step_for(ch->out_period, ch->sample ? ch->sample->finetune : 0, p->rate);
    }
    if (++p->tick >= p->speed) {
        p->tick = 0;
        if (p->pattern_delay > 0) {                              // EEx: replay the row
            p->pattern_delay--;
            p->repeat_row = 1;
        } else {
            p->repeat_row = 0;
            next_row(p);
        }
    }
}
```

> **Note:** Treating every backward `B` jump as the end of the song is a simplification. A few songs jump backwards mid-song on purpose. If you hit one, replace the check with a record of which `(order, row)` pairs have already been played, and end when one repeats.

## What's next

You now have a working MOD player behind a four-function API. Before moving on, a few optional extensions are worth trying while the code is fresh:

- **Linear interpolation.** Blend the two neighbouring sample bytes by the fractional position. Compare the sound with nearest-neighbour. Many people prefer the crunch.
- **A live display.** Print the current row of every channel as it plays, or draw a VU meter per channel in the terminal. Remember the callback rule: read the player state from the main thread under the stream lock, never print from inside the callback.
- **Exact ProTracker finetune.** Replace the `pow` approximation with ProTracker's 16 period tables. You will find them in any ProTracker source port.

**Part 2** turns the player into a tracker. You will draw the pattern grid with SDL3, move a cursor around it, enter notes from the keyboard, edit samples and effects, and save the result back to a valid `.mod`. The hardest new problem is safely changing the song while the audio thread is playing it.

After that comes the demo. Because the player only needs `player_render` to be called with a buffer, dropping it into a demo is a few lines of code. Your effects can even read the player's current row and channel volumes to sync visuals to the music, which is exactly how many classic demos did it.

## Sources

- [ProTracker 2.3A Song/Module Format](https://www.lim.di.unimi.it/IEEE/VROS/MOD.HTM): Lars Hamre's format notes, with later updates
- [Protracker Module](https://wiki.multimedia.cx/index.php/Protracker_Module): MultimediaWiki, signatures and effect notes
- [pt2\_replayer.c](https://github.com/8bitbubsy/pt2-clone/blob/master/src/pt2_replayer.c): pt2-clone's C port of the ProTracker 2.3D replayer, used to check effect behaviour
- [ProTracker command reference](https://stef.be/bassoontracker/docs/ProtrackerCommandReference.pdf): BassoonTracker documentation
- [MOD (file format)](<https://en.wikipedia.org/wiki/MOD_(file_format)>): Wikipedia, history
- [SDL\_LockAudioStream](https://wiki.libsdl.org/SDL3/SDL_LockAudioStream): SDL3 wiki, callback locking
- [openmpt123](https://mankier.com/1/openmpt123): command-line manual
