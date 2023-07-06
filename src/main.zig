pub const UNICODE = true;

// Imports

const builtin = @import("builtin");
const std     = @import("std");

const print  = std.debug.print;
const WINAPI = std.os.windows.WINAPI;

const gl  = @import("gl");
const w32 = @import("win32").everything;

// Constants that zigwin32/zig-opengl doesn't provide

const WGL_CONTEXT_MAJOR_VERSION_ARB     = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB     = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB      = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB  = 0x00000001;

const WGL_DRAW_TO_WINDOW_ARB     = 0x2001;
const WGL_ACCELERATION_ARB       = 0x2003;
const WGL_SUPPORT_OPENGL_ARB     = 0x2010;
const WGL_DOUBLE_BUFFER_ARB      = 0x2011;
const WGL_PIXEL_TYPE_ARB         = 0x2013;
const WGL_COLOR_BITS_ARB         = 0x2014;
const WGL_DEPTH_BITS_ARB         = 0x2022;
const WGL_STENCIL_BITS_ARB       = 0x2023;
const WGL_FULL_ACCELERATION_ARB  = 0x2027;
const WGL_TYPE_RGBA_ARB          = 0x202B;

var gl_library: w32.HINSTANCE = undefined;

const Win32Channel = struct {
    source: ?*w32.IXAudio2SourceVoice,
};

const Channel = struct {
    sound_id: []const u8,
    platform: switch (builtin.os.tag) {
        .windows => Win32Channel,
        else => @panic("Unsupported OS (Channel.platform)"),
    },
};

const Sound = struct {
    id: []const u8,
    size: u32,
    buffer: []u8,

    // TODO: MOVE THIS SOMEWHERE ELSE
    src: ?*w32.IXAudio2SourceVoice,
};

const WAVEFormat = struct {
    channels: u32,
    samples_per_second: u32,
    bits_per_sample: u32,
    block_align: u32,
    avg_bytes_per_sec: u32,
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
    fmt  = (@as(u32, "f"[0]) << 0) | (@as(u32, "m"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, " "[0]) << 24),
    data = (@as(u32, "d"[0]) << 0) | (@as(u32, "a"[0]) << 8) | (@as(u32, "t"[0]) << 16) | (@as(u32, "a"[0]) << 24),
};

const Win32Audio = struct {
    xaudio2: ?*w32.IXAudio2,
    master: ?*w32.IXAudio2MasteringVoice,
};

const Audio = struct {
    allocator: std.mem.Allocator,
    platform: switch (builtin.os.tag) {
        .windows => Win32Audio,
        else => @panic("Unsupported OS for Audio.platform\n"),
    },

    pub fn init(allocator: std.mem.Allocator) !Audio {
        var a: Audio = undefined;
        a.allocator = allocator;

        switch (builtin.os.tag) {
            .windows => {
                if (w32.XAudio2Create(&a.platform.xaudio2, 0, w32.XAUDIO2_DEFAULT_PROCESSOR) != w32.S_OK) {
                    return error.XAudio2InitFail;
                }

                if (w32.IXAudio2.IXAudio2_CreateMasteringVoice(a.platform.xaudio2.?, &a.platform.master, w32.XAUDIO2_DEFAULT_CHANNELS,
                    w32.XAUDIO2_DEFAULT_SAMPLERATE, 0, null, null, @enumFromInt(0)) != w32.S_OK) {
                    return error.XAudio2InitFail;
                }
            },

            else => @panic("Unsupported OS"),
        }

        return a;
    }

    pub fn load_sound(self: *Audio, path: []const u8) !Sound {
        var sound: Sound = undefined;
        sound.id = path;

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var file_buffer = try file.readToEndAlloc(self.allocator, (try file.stat()).size);
        defer self.allocator.free(file_buffer);

        const header: WAVEHeader = @bitCast(file_buffer[0..12].*);

        var start: usize = 12;
        const end = header.cksize - 4;

        while (start < end) {
            const chunk: WAVEChunkHeader = @bitCast(file_buffer[start..][0..@sizeOf(WAVEChunkHeader)].*);

            switch (chunk.ckID) {
                @intFromEnum(WAVEChunkID.fmt) => {
                    const fmt_chunk: WAVEfmtChunk = @bitCast(file_buffer[start + @sizeOf(WAVEChunkHeader)..][0..@sizeOf(WAVEfmtChunk)].*);

                    // TODO: Check that this is valid
                    print("wFormatTag: {}\n", .{fmt_chunk.wFormatTag});
                    print("nChannels: {}\n", .{fmt_chunk.nChannels});
                    print("nSamplesPerSec: {}\n", .{fmt_chunk.nSamplesPerSec});
                    print("wBitsPerSample: {}\n", .{fmt_chunk.wBitsPerSample});
                    print("nBlockAlign: {}\n", .{fmt_chunk.nBlockAlign});
                    print("nAvgBytesPerSec: {}\n", .{fmt_chunk.nAvgBytesPerSec});
                },

                @intFromEnum(WAVEChunkID.data) => {
                    print("Data chunk found\n", .{});

                    sound.size = chunk.cksize;
                    sound.buffer = try self.allocator.alloc(u8, sound.size);
                    std.mem.copy(u8, sound.buffer, file_buffer[start + @sizeOf(WAVEChunkHeader)..]);
                },

                else => {},
            }

            start += @sizeOf(WAVEChunkHeader) + ((chunk.cksize + 1) & ~@as(u32, 1));
        }

        return sound;
    }

    pub fn unload_sound(self: *Audio, sound: *const Sound) void {
        self.allocator.free(sound.buffer);
    }
};

fn get_string(s: u32) [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(w32.glGetString(s))));
}

fn get_proc_address(comptime cxt: @TypeOf(null), entry_point: [:0]const u8) ?*anyopaque {
    _ = cxt;

    if (gl_library != undefined) {
        const T = *const fn (entry_point: [*:0]const u8) ?*anyopaque;

        // Load >1.1 function
        if (w32.GetProcAddress(gl_library, "wglGetProcAddress")) |wglGetProcAddress| {
            if (@as(T, @ptrCast(wglGetProcAddress))(entry_point.ptr)) |ptr| {
                return @constCast(ptr);
            }
        }

        // Load <=1.1 function
        if (w32.GetProcAddress(gl_library, entry_point.ptr)) |ptr| {
            return @constCast(ptr);
        }
    }

    if (w32.wglGetProcAddress(entry_point.ptr)) |ptr| {
        return @constCast(ptr);
    }

    return null;
}

pub fn main() !void {
    _ = w32.CoInitializeEx(null, w32.COINIT_MULTITHREADED);

    // Playing with audio

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var audio = try Audio.init(gpa.allocator());
    const sound = try audio.load_sound("D:\\projects\\moon\\res\\test_audio.wav");
    defer audio.unload_sound(&sound);

    // TODO: Load this from file?
    const wave_format = w32.WAVEFORMATEX {
        .wFormatTag = w32.WAVE_FORMAT_PCM,
        .nChannels = 2,
        .nSamplesPerSec = 44100,
        .wBitsPerSample = 16,
        .nBlockAlign = 4,
        .nAvgBytesPerSec = 44100 * 4,
        .cbSize = 0,
    };

    const buffer = w32.XAUDIO2_BUFFER {
        .Flags = w32.XAUDIO2_END_OF_STREAM,
        .AudioBytes = sound.size,
        .pAudioData = @ptrCast(sound.buffer),
        .PlayBegin = 0,
        .PlayLength = 0,
        .LoopBegin = 0,
        .LoopLength = 0,
        .LoopCount = 0,
        .pContext = null,
    };

    var src: ?*w32.IXAudio2SourceVoice = undefined;
    _ = w32.IXAudio2.IXAudio2_CreateSourceVoice(audio.platform.xaudio2.?, &src, &wave_format, 0, 1.0, null, null, null);
    _ = w32.IXAudio2SourceVoice.IXAudio2SourceVoice_SubmitSourceBuffer(src.?, &buffer, null);
    _ = w32.IXAudio2Voice.IXAudio2Voice_SetVolume(@ptrCast(src.?), 0.1, 0);
     _ = w32.IXAudio2SourceVoice.IXAudio2SourceVoice_Start(src.?, 0, 0);
    
    // Window creation

    const module_handle = w32.GetModuleHandleW(null) orelse unreachable;
    const class_name = w32.L("MOON");

    const window_class = w32.WNDCLASSEXW{
        .style = w32.WNDCLASS_STYLES.initFlags(.{ .OWNDC = 1, .HREDRAW = 1, .VREDRAW = 1 }),
        .lpfnWndProc = win32_callback,
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .cbClsExtra = 0,
        .cbWndExtra = @sizeOf(usize),
        .hInstance = @ptrCast(module_handle),
        .hIcon = null,
        .hCursor = null,
        .lpszMenuName = null,
        .hbrBackground = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&window_class) == 0) {
        return error.WindowCreationFailed;
    }

    var rect = w32.RECT{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, @enumFromInt(0));
    const x = w32.CW_USEDEFAULT;
    const y = w32.CW_USEDEFAULT;
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;

    const title = w32.L("Moon");

    const handle = w32.CreateWindowExW(@enumFromInt(0), class_name, title, w32.WS_OVERLAPPEDWINDOW, x, y, w, h, null, null, module_handle, null) 
        orelse return error.WindowCreationFailed;

    // Loading OpenGL

    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nVersion = 1,
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 0,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = w32.PFD_MAIN_PLANE,
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const hdc = w32.GetDC(handle) orelse @panic("Unable to access DC");
    defer _ = w32.ReleaseDC(handle, hdc);

    const quasi_format = w32.ChoosePixelFormat(hdc, &pfd);
    _ = w32.SetPixelFormat(hdc, quasi_format, &pfd);

    const quasi_context = w32.wglCreateContext(hdc) orelse @panic("Couldn't create WGL context");
    _ = w32.wglMakeCurrent(hdc, quasi_context);
    errdefer _ = w32.wglDeleteContext(quasi_context);

    const wglChoosePixelFormatARB = @as(
        *const fn (
            hdc: w32.HDC,
            piAttribIList: ?[*:0]const c_int,
            pfAttribFList: ?[*:0]const f32,
            nMaxFormats: c_uint,
            piFormats: [*]c_int,
            nNumFormats: *c_uint,
        ) callconv(WINAPI) w32.BOOL,
        @ptrCast(w32.wglGetProcAddress("wglChoosePixelFormatARB") orelse return error.InvalidOpenGL),
    );

    const wglCreateContextAttribsARB = @as(
        *const fn (
            hdc: w32.HDC,
            hshareContext: ?w32.HGLRC,
            attribList: ?[*:0]const c_int,
        ) callconv(WINAPI) ?w32.HGLRC,
        @ptrCast(w32.wglGetProcAddress("wglCreateContextAttribsARB") orelse return error.InvalidOpenGL),
    );

    const pfd_attributes = [_:0]c_int{
        WGL_DRAW_TO_WINDOW_ARB, gl.TRUE,
        WGL_SUPPORT_OPENGL_ARB, gl.TRUE,
        WGL_DOUBLE_BUFFER_ARB,  gl.TRUE,
        WGL_PIXEL_TYPE_ARB,     WGL_TYPE_RGBA_ARB,
        WGL_COLOR_BITS_ARB,     32,
        WGL_DEPTH_BITS_ARB,     24,
        WGL_STENCIL_BITS_ARB,   8,
        0, // end flag
    };

    var format: c_int = undefined;
    var format_count: c_uint = undefined;

    if (wglChoosePixelFormatARB(hdc, &pfd_attributes, null, 1, @as([*]c_int, @ptrCast(&format)), &format_count) == 0 or format_count == 0) {
        return error.InvalidOpenGL;
    }

    if (quasi_format != format) {
        @panic("Stop being lazy and implement the recreating window");
    }

    const context_attributes = [_:0]c_int{
        WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
        WGL_CONTEXT_MINOR_VERSION_ARB, 3,
        WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0, // end flag
    };

    const context = wglCreateContextAttribsARB(hdc, null, &context_attributes) orelse return error.InvalidOpenGL;
    errdefer _ = w32.wglDeleteContext(context);

    if (w32.wglMakeCurrent(hdc, context) == 0) {
        return error.InvalidOpenGL;
    }

    gl_library = w32.LoadLibraryW(w32.L("opengl32.dll")) orelse @panic("Can't find opengl32.dll");
    try gl.load(null, get_proc_address);

    _ = w32.ShowWindow(handle, w32.SW_SHOW);

    // Playing with OpenGL

    const vertex_source =
        \\ #version 410 core
        \\ layout (location = 0) in vec3 aPos;
        \\ void main()
        \\ {
        \\   gl_Position = vec4(aPos.x, aPos.y, aPos.z, 1.0);
        \\ }
    ; 

    const fragment_source =
        \\ #version 410 core
        \\ out vec4 FragColor;
        \\ void main() {
        \\  FragColor = vec4(1.0, 1.0, 0.2, 1.0);   
        \\ }
    ;

    var success: c_int = undefined;
    var shader_log: [512]u8 = [_]u8{0} ** 512;
    
    const fragment_shader = gl.createShader(gl.FRAGMENT_SHADER);
    gl.shaderSource(fragment_shader, 1, @as([*c]const [*c]const u8, @ptrCast(&fragment_source)), null);
    gl.compileShader(fragment_shader);

    gl.getShaderiv(fragment_shader, gl.COMPILE_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(fragment_shader, 512, 0, &shader_log);
        print("Shader Error: {s}\n", .{ shader_log });
    }
    
    const vertex_shader = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vertex_shader, 1, @as([*c]const [*c]const u8, @ptrCast(&vertex_source)), null);
    gl.compileShader(vertex_shader);

    gl.getShaderiv(vertex_shader, gl.COMPILE_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(vertex_shader, 512, 0, &shader_log);
        print("Shader Error: {s}\n", .{ shader_log });
    }

    const shader = gl.createProgram();
    gl.attachShader(shader, vertex_shader);
    gl.attachShader(shader, fragment_shader);
    gl.linkProgram(shader);

    gl.getProgramiv(shader, gl.LINK_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(shader, 512, 0, &shader_log);
        print("Shader Error: {s}\n", .{ shader_log });
    }

    gl.deleteShader(vertex_shader);
    gl.deleteShader(fragment_shader);

    defer gl.deleteProgram(shader);

    const vertices = [9]f32{ -0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.0, 0.5, 0.0 };
    var VBO: c_uint = undefined;
    var VAO: c_uint = undefined;

    gl.genVertexArrays(1, &VAO);
    defer gl.deleteVertexArrays(1, &VAO);

    gl.genBuffers(1, &VBO);
    defer gl.deleteBuffers(1, &VBO);

    gl.bindVertexArray(VAO);
    gl.bindBuffer(gl.ARRAY_BUFFER, VBO);
    gl.bufferData(gl.ARRAY_BUFFER, vertices.len * @sizeOf(f32), &vertices, gl.STATIC_DRAW);

    gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), null);
    gl.enableVertexAttribArray(0);

    // Runtime

    var running = true;
    while (running) {
        var msg: w32.MSG = undefined;
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            if (msg.message == w32.WM_QUIT) {
                running = false;
            } else {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
        }

        gl.clearColor(1.0, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.useProgram(shader);
        gl.bindVertexArray(VAO);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        // TODO: Change this to the WGL extension version (probably)
        _ = w32.SwapBuffers(hdc);
    }
}

fn win32_callback(hwnd: w32.HWND, uMsg: u32, wParam: w32.WPARAM, lParam: w32.LPARAM) callconv(WINAPI) w32.LRESULT {
    var result: w32.LRESULT = 0;

    switch (uMsg) {
        w32.WM_CLOSE, w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
        },

        else => {
            result = w32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
        },
    }

    return result;
}
