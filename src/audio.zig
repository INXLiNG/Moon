const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32").everything;

pub const Win32Channel = struct {
    source: ?*w32.IXAudio2SourceVoice,
    buffer: w32.XAUDIO2_BUFFER,
};

pub const Channel = struct {
    sound_id: []const u8,
    platform: switch (builtin.os.tag) {
        .windows => Win32Channel,
        else => @panic("Unsupported OS (Channel.platform)"),
    },
};

pub const Sound = struct {
    id: []const u8,
    size: u32,
    buffer: []u8,

    references: u32,
};

pub const WAVEFormat = struct {
    channels: u16,
    samples_per_second: u32,
    bits_per_sample: u16,
    block_align: u16,
};

const WAVEHeader = packed struct {
    ckID: u32,
    cksize: u32,
    WAVEID: u32,
};

const WAVEChunkHeader = packed struct {
    ckID: u32,
    cksize: u32,
};

const WAVEfmtChunk = packed struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
    wValidBitsPerSample: u16,
    dwChannelMask: u32,
    subFormat: u128,
};

const WAVEChunkID = enum(u32) {
    RIFF = (@as(u32, "R"[0]) << 0) | (@as(u32, "I"[0]) << 8) | (@as(u32, "F"[0]) << 16) | (@as(u32, "F"[0]) << 24),
    WAVE = (@as(u32, "W"[0]) << 0) | (@as(u32, "A"[0]) << 8) | (@as(u32, "V"[0]) << 16) | (@as(u32, "E"[0]) << 24),
    fmt = (@as(u32, "f"[0]) << 0) | (@as(u32, "m"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, " "[0]) << 24),
    data = (@as(u32, "d"[0]) << 0) | (@as(u32, "a"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, "a"[0]) << 24),
};

const Win32Audio = struct {
    xaudio2: ?*w32.IXAudio2,
    master: ?*w32.IXAudio2MasteringVoice,
    format: w32.WAVEFORMATEX,
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    sounds: std.StringHashMap(Sound),
    format: WAVEFormat,

    platform: switch (builtin.os.tag) {
        .windows => Win32Audio,
        else => @panic("Unsupported OS for AudioEngine.platform\n"),
    },

    pub fn init(allocator: std.mem.Allocator, format: WAVEFormat) !AudioEngine {
        // TODO: Put proper error handling in this function

        var audio = AudioEngine {
            .allocator = allocator,
            .sounds    = std.StringHashMap(Sound).init(allocator),
            .format    = format,
            .platform  = undefined,
        };

        const platform: *@TypeOf(audio.platform) = &audio.platform;
        switch (builtin.os.tag) {
            // XAudio2 initialization
            .windows => {
                platform.format = w32.WAVEFORMATEX {
                    .wFormatTag = w32.WAVE_FORMAT_PCM,
                    .nChannels = format.channels,
                    .nSamplesPerSec = format.samples_per_second,
                    .wBitsPerSample =  format.bits_per_sample,
                    .nBlockAlign =  format.block_align,
                    .nAvgBytesPerSec = format.samples_per_second * format.block_align,
                    .cbSize = 0,
                };

                // Defaults taken from:
                // https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/nf-xaudio2-xaudio2create
                if (w32.XAudio2Create(
                    &platform.xaudio2, 
                    0, 
                    w32.XAUDIO2_DEFAULT_PROCESSOR) != w32.S_OK) {
                    return error.XAudio2InitFail;
                }

                // Defaults taken from:
                // https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/nf-xaudio2-ixaudio2-createmasteringvoice
                if (w32.IXAudio2.IXAudio2_CreateMasteringVoice(
                    platform.xaudio2.?, 
                    &platform.master, 
                    w32.XAUDIO2_DEFAULT_CHANNELS, 
                    w32.XAUDIO2_DEFAULT_SAMPLERATE, 
                    0, 
                    null,
                    null,
                    @enumFromInt(0)) != w32.S_OK) {
                    return error.XAudio2InitFail;
                }
            },

            else => @panic("Unsupported OS"),
        }

        return audio;
    }

    pub fn deinit(self: *AudioEngine) void {
        // NOTE: Technically this shouldn't have any sounds in it once the reference counting system is in place
        // maybe this should output a leak error in that case? For now this is functional enough as is.
        var it = self.sounds.iterator();
        while (it.next()) |sound| { self.allocator.free(sound.value_ptr.buffer); }

        self.sounds.deinit();
    }

    pub fn load_sound(self: *AudioEngine, path: []const u8) !void {
        // WAV file formation specification:
        // https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html

        if (self.sounds.getPtr(path)) |sound| {
            sound.references += 1;
        }

        else {
            var sound: Sound = undefined;
            sound.id = path;
            sound.references = 1;

            var file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            var file_buffer = try file.readToEndAlloc(self.allocator, (try file.stat()).size);
            defer self.allocator.free(file_buffer);

            const header: WAVEHeader = @bitCast(file_buffer[0..12].*);
            std.debug.assert(header.ckID == @intFromEnum(WAVEChunkID.RIFF));
            std.debug.assert(header.WAVEID == @intFromEnum(WAVEChunkID.WAVE));

            var start: usize = 12;
            while (start < header.cksize - 4) {
                const chunk: WAVEChunkHeader = @bitCast(file_buffer[start..][0..@sizeOf(WAVEChunkHeader)].*);

                switch (chunk.ckID) {
                    @intFromEnum(WAVEChunkID.fmt) => {
                        const fmt_chunk: WAVEfmtChunk = @bitCast(file_buffer[start + @sizeOf(WAVEChunkHeader) ..][0..@sizeOf(WAVEfmtChunk)].*);

                        // NOTE: Should this be replaced with a different assert?
                        std.debug.assert(fmt_chunk.wFormatTag == w32.WAVE_FORMAT_PCM);
                        std.debug.assert(fmt_chunk.nChannels == self.format.channels);
                        std.debug.assert(fmt_chunk.nSamplesPerSec == self.format.samples_per_second);
                        std.debug.assert(fmt_chunk.wBitsPerSample == self.format.bits_per_sample);
                        std.debug.assert(fmt_chunk.nBlockAlign == self.format.block_align);
                    },

                    @intFromEnum(WAVEChunkID.data) => {
                        sound.size = chunk.cksize;

                        sound.buffer = try self.allocator.alloc(u8, sound.size);
                        std.mem.copy(u8, sound.buffer, file_buffer[start + @sizeOf(WAVEChunkHeader) ..]);
                    },

                    else => {},
                }

                // Bitwise trickery since "data" chunks can have pad bytes if there are an odd number of samples
                // Essentially just forces the increment to round up to the next even number if the result is odd 
                start += @sizeOf(WAVEChunkHeader) + ((chunk.cksize + 1) & ~@as(u32, 1));
            }

            try self.sounds.put(path, sound);
        }
    }

    pub fn play_sound(self: *AudioEngine, id: []const u8, channel: *Channel) void {
        // TODO: Add error if this returns incorrect value
        const sound = self.sounds.get(id).?;

        // Just done to make calls less encumbersome (i.e. no channel.platform.source, etc.)
        const p: *@TypeOf(channel.platform) = &channel.platform;

        p.buffer.AudioBytes = sound.size;
        p.buffer.pAudioData = @ptrCast(sound.buffer);

        // TODO: Put actual error handling here
        _ = w32.IXAudio2SourceVoice.IXAudio2SourceVoice_SubmitSourceBuffer(p.source.?, &p.buffer, null);
        _ = w32.IXAudio2Voice.IXAudio2Voice_SetVolume(@ptrCast(p.source.?), 0.1, 0);
        _ = w32.IXAudio2SourceVoice.IXAudio2SourceVoice_Start(p.source.?, 0, 0);
    }

    pub fn unload_sound(self: *AudioEngine, id: []const u8) void {
        if (self.sounds.getPtr(id)) |sound| {
            sound.references -= 1;
            std.debug.print("{any} references to {s} remaining...\n", .{ sound.references, id });

            if (sound.references == 0) {
                std.debug.print("Now unloading {s}...\n", .{ id });
                self.allocator.free(sound.buffer);

                // Ignore return result since we know this always succeeds
                _ = self.sounds.remove(id);
            }
        }
    }
};