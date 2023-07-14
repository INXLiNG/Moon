// std
const std    = @import("std");
const WINAPI = std.os.windows.WINAPI;

// os-level stuff
const builtin = @import("builtin");
const w32     = @import("win32").everything;

/// Maximum number of sounds that can be loaded into memory at a given time
pub const MAX_SOUNDS: usize = 128;

/// Maximum number of channels through which sounds can be playing (MAX_CHANNELS <= MAX_SOUNDS)
pub const MAX_CHANNELS: usize = 32;

/// 64-bit handle to reference Sound objects in the pool.
/// 
/// Constructed from a 32-bit index and 32-bit generation; allows for
/// a maximum of 549,755,813,760 unique sound objects to be
/// allocated across the lifetime of the program.
/// 
/// For more info on handles vs. pointers: 
///   https://floooh.github.io/2018/06/17/handles-vs-pointers.html
pub const SoundHandle = struct {
    index: u32,
    generation: u32,
};

const Sound = struct {
    data: ?[]const u8,
};

const SoundPool = struct {
    sounds: []Sound,
    generations: []u32,

    fn init(allocator: std.mem.Allocator) SoundPool {
        return .{
            .sounds = blk: {
                var sounds = allocator.alloc(Sound, MAX_SOUNDS) catch unreachable;
                for (sounds) |*sound| {
                    sound.data = null;
                }

                break :blk sounds;
            },

            .generations = blk: {
                var generations = allocator.alloc(u32, MAX_SOUNDS) catch unreachable;
                for (generations) |*generation| {
                    generation.* = 0;
                }

                break :blk generations;
            }
        };
    }

    fn deinit(this: *SoundPool, allocator: std.mem.Allocator) void {
        for (this.sounds) |sound| {
            if (sound.data != null) 
                allocator.free(sound.data.?);
        }

        allocator.free(this.sounds);
        allocator.free(this.generations);

        this.* = undefined;
    }

    fn add_sound(this: *SoundPool, data: []const u8) SoundHandle {
        // find empty spot in the pool
        var idx: u32 = 0;
        while (idx < MAX_SOUNDS) : (idx += 1) {
            if (this.sounds[idx].data == null)
                break;
        }

        // NOTE(selina): Should this error out in a release build?
        // For debugging purposes this is acceptable.
        std.debug.assert(idx < MAX_SOUNDS);

        this.sounds[idx].data = data;
        this.generations[idx] += 1;

        return .{
            .index = idx,
            .generation = this.generations[idx]
        };
    }

    fn remove_sound(this: *SoundPool, sound_handle: SoundHandle, allocator: std.mem.Allocator) void {
        if (this.get_sound(sound_handle)) |sound| {
            allocator.free(sound.data.?);
            this.sounds[sound_handle.index] = null;
        }
    }

    fn get_sound(this: *SoundPool, sound_handle: SoundHandle) ?*Sound {
        std.debug.assert(sound_handle.index < MAX_SOUNDS);
        
        var sound: *Sound = undefined;
        if (this.generations[sound_handle.index] == sound_handle.generation) {
            sound = &this.sounds[sound_handle.index];
        }

        return sound;
    }
};

const WAVFileHeader = packed struct {
    ckID: u32,
    cksize: u32,
    WAVEID: u32,
};

const WAVFileChunkHeader = packed struct {
    ckID: u32,
    cksize: u32,
};

const WAVFileFmtChunk = packed struct {
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

const WAVFileChunkID = enum(u32) {
    RIFF = (@as(u32, "R"[0]) << 0) | (@as(u32, "I"[0]) << 8) | (@as(u32, "F"[0]) << 16) | (@as(u32, "F"[0]) << 24),
    WAVE = (@as(u32, "W"[0]) << 0) | (@as(u32, "A"[0]) << 8) | (@as(u32, "V"[0]) << 16) | (@as(u32, "E"[0]) << 24),
    fmt = (@as(u32, "f"[0]) << 0) | (@as(u32, "m"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, " "[0]) << 24),
    data = (@as(u32, "d"[0]) << 0) | (@as(u32, "a"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, "a"[0]) << 24),
};

const preferred_format = w32.WAVEFORMATEX {
    .wFormatTag = w32.WAVE_FORMAT_PCM,
    .nChannels = 2,
    .nSamplesPerSec = 44100,
    .nAvgBytesPerSec = 44100 * 4,
    .nBlockAlign = 4,
    .wBitsPerSample = 16,
    .cbSize = 0,
};

inline fn hr_panic(result: w32.HRESULT) void {
    if (result != w32.S_OK) @panic("Error");
}

const Win32SimpleAudioCallback = struct {
    usingnamespace w32.IXAudio2VoiceCallback.MethodMixin(@This());
    __v: *const w32.IXAudio2VoiceCallback.VTable = &vtable,

    const vtable = w32.IXAudio2VoiceCallback.VTable {
        .OnVoiceProcessingPassStart = OnVoiceProcessingPassStart,
        .OnVoiceProcessingPassEnd   = OnVoiceProcessingPassEnd,
        .OnStreamEnd                = OnStreamEnd,
        .OnBufferStart              = OnBufferStart,
        .OnBufferEnd                = OnBufferEnd,
        .OnLoopEnd                  = OnLoopEnd,
        .OnVoiceError               = OnVoiceError,
    };

    fn OnVoiceProcessingPassStart(_: *const w32.IXAudio2VoiceCallback, _: u32) callconv(WINAPI) void {}
    fn OnVoiceProcessingPassEnd(_: *const w32.IXAudio2VoiceCallback) callconv(WINAPI) void {}
    fn OnStreamEnd(_: *const w32.IXAudio2VoiceCallback) callconv(WINAPI) void {}
    fn OnBufferStart(_: *const w32.IXAudio2VoiceCallback, _: ?*anyopaque) callconv(WINAPI) void { }
    fn OnLoopEnd(_: *const w32.IXAudio2VoiceCallback, _: ?*anyopaque) callconv(WINAPI) void {}
    fn OnVoiceError(_: *const w32.IXAudio2VoiceCallback, _: ?*anyopaque, _: w32.HRESULT) callconv(WINAPI) void {}

    fn OnBufferEnd(_: *const w32.IXAudio2VoiceCallback, context: ?*anyopaque) callconv(WINAPI) void {
        const source_voice = @as(*w32.IXAudio2SourceVoice, @ptrCast(@alignCast(context)));
        
        hr_panic(w32.IXAudio2SourceVoice.IXAudio2SourceVoice_Stop(source_voice, 0, 0));
        hr_panic(w32.IXAudio2SourceVoice.IXAudio2SourceVoice_FlushSourceBuffers(source_voice));
    }
};

var simple_audio_callback = Win32SimpleAudioCallback{};

const Win32Platform = struct {
    xaudio2: ?*w32.IXAudio2,
    master_voice: ?*w32.IXAudio2MasteringVoice,

    source_voices: [MAX_CHANNELS]?*w32.IXAudio2SourceVoice,
    buffers: [MAX_CHANNELS]w32.XAUDIO2_BUFFER,

    format: w32.WAVEFORMATEX,
};

fn init_win32() Win32Platform {
    var this: Win32Platform = undefined;
    this.format = preferred_format;

    this.xaudio2 = blk: {
        var xaudio2: ?*w32.IXAudio2 = null;
        hr_panic(w32.XAudio2Create(&xaudio2, 0, w32.XAUDIO2_DEFAULT_PROCESSOR));

        break :blk xaudio2;
    };

    this.master_voice = blk: {
        var master_voice: ?*w32.IXAudio2MasteringVoice = null;
        hr_panic(w32.IXAudio2.IXAudio2_CreateMasteringVoice(
            this.xaudio2.?, 
            &master_voice,
            w32.XAUDIO2_DEFAULT_CHANNELS, 
            w32.XAUDIO2_DEFAULT_SAMPLERATE, 
            0, 
            null, 
            null, 
            @enumFromInt(0)));

        break :blk master_voice;
    };

    for (0..MAX_CHANNELS) |idx| {
        var source_voice: ?*w32.IXAudio2SourceVoice = null;
        hr_panic(w32.IXAudio2.IXAudio2_CreateSourceVoice(
            this.xaudio2.?,
            &source_voice,
            &preferred_format,
            0,
            1.0,
            @as(*w32.IXAudio2VoiceCallback, @ptrCast(&simple_audio_callback)),
            null,
            null,
        ));
        this.source_voices[idx] = source_voice;
    }

    return this;
}

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    sound_pool: SoundPool,

    platform: switch(builtin.os.tag) {
        .windows => Win32Platform,
        else => @panic("Unsupported OS in AudioEngine.platform"),
    },

    pub fn init(allocator: std.mem.Allocator) AudioEngine {
        var engine: AudioEngine = undefined;
        engine.allocator = allocator;
        engine.sound_pool = SoundPool.init(engine.allocator);

        engine.platform = switch(builtin.os.tag) {
            .windows => init_win32(),
            else => @panic("Unsupported OS in AudioEngine.init")
        };

        return engine;
    }

    pub fn deinit(this: *AudioEngine) void {
        this.sound_pool.deinit(this.allocator);

        switch(builtin.os.tag) {
            .windows => {
                for (this.platform.source_voices) |source_voice| {
                    w32.IXAudio2Voice.IXAudio2Voice_DestroyVoice(@ptrCast(source_voice));
                }

                w32.IXAudio2Voice.IXAudio2Voice_DestroyVoice(@ptrCast(this.platform.master_voice));
                _ = w32.IUnknown.IUnknown_Release(@ptrCast(this.platform.xaudio2));
            },

            else => @panic("Unsupported OS in AudioEngine.deinit"),
        }

        this.* = undefined;
    }

    pub fn load_sound(this: *AudioEngine, fpath: []const u8) SoundHandle {
        // reading in the file
        const file = std.fs.cwd().openFile(fpath, .{}) catch unreachable;
        defer file.close();

        const file_buffer = file.readToEndAlloc(this.allocator, (file.stat() catch unreachable).size) catch unreachable;
        defer this.allocator.free(file_buffer);

        // file parsing
        const wav_header: WAVFileHeader = @bitCast(file_buffer[0..12].*);
        std.debug.assert(wav_header.ckID == @intFromEnum(WAVFileChunkID.RIFF));
        std.debug.assert(wav_header.WAVEID == @intFromEnum(WAVFileChunkID.WAVE));

        var data: []u8 = undefined;
        var idx: usize = 12;
        while (idx < wav_header.cksize - 4) {
            const chunk: WAVFileChunkHeader = @bitCast(file_buffer[idx..][0..@sizeOf(WAVFileChunkHeader)].*);

            switch (chunk.ckID) {
                @intFromEnum(WAVFileChunkID.fmt) => {
                    const fmt: WAVFileFmtChunk = @bitCast(file_buffer[idx + @sizeOf(WAVFileChunkHeader) ..][0..@sizeOf(WAVFileFmtChunk)].*);

                    std.debug.assert(fmt.wFormatTag == w32.WAVE_FORMAT_PCM);
                    std.debug.assert(fmt.nChannels == this.platform.format.nChannels);
                    std.debug.assert(fmt.nSamplesPerSec == this.platform.format.nSamplesPerSec);
                    std.debug.assert(fmt.wBitsPerSample == this.platform.format.wBitsPerSample);
                    std.debug.assert(fmt.nBlockAlign == this.platform.format.nBlockAlign);
                },

                @intFromEnum(WAVFileChunkID.data) => {
                    data = this.allocator.alloc(u8, chunk.cksize) catch unreachable;
                    std.mem.copy(u8, data, file_buffer[idx + @sizeOf(WAVFileChunkHeader) ..]);
                },

                else => {},
            }

            idx += @sizeOf(WAVFileChunkHeader) + ((chunk.cksize + 1) & ~@as(u32, 1));
        }

        return this.sound_pool.add_sound(data);
    }

    pub fn play_sound(this: *AudioEngine, sound_handle: SoundHandle) void {
        switch(builtin.os.tag) {
            .windows => {
                // obtain an idle source voice
                var idx: usize = 0;
                while (idx < MAX_CHANNELS) : (idx += 1) {
                    if (this.platform.source_voices[idx]) |voice| {
                        var voice_state: w32.XAUDIO2_VOICE_STATE = undefined;
                        w32.IXAudio2SourceVoice.IXAudio2SourceVoice_GetState(voice, &voice_state, 0);

                        if (voice_state.BuffersQueued == 0) break;
                    }

                }

                std.debug.assert(idx < MAX_CHANNELS);

                const sound = this.sound_pool.get_sound(sound_handle).?;

                this.platform.buffers[idx] = .{
                    .Flags = w32.XAUDIO2_END_OF_STREAM,
                    .AudioBytes = @as(u32, @intCast(sound.data.?.len)),
                    .pAudioData = @ptrCast(sound.data.?.ptr),
                    .PlayBegin = 0,
                    .PlayLength = 0,
                    .LoopBegin = 0,
                    .LoopLength = 0,
                    .LoopCount = 0,
                    .pContext = this.platform.source_voices[idx].?,
                };

                _ = w32.IXAudio2SourceVoice.IXAudio2SourceVoice_SubmitSourceBuffer(
                    this.platform.source_voices[idx].?, 
                    &this.platform.buffers[idx], 
                    null);
                
                hr_panic(w32.IXAudio2Voice.IXAudio2Voice_SetVolume(@ptrCast(this.platform.source_voices[idx].?), 0.1, 0));
                hr_panic(w32.IXAudio2SourceVoice.IXAudio2SourceVoice_Start(this.platform.source_voices[idx].?, 0, 0));
            },

            else => @panic("Unsupported OS in AudioEngine.play_sound"),
        }
    }
};