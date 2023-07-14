pub const UNICODE = true;

// Imports

const builtin = @import("builtin");
const std     = @import("std");
const gl      = @import("gl");
const w32     = @import("win32").everything;

const print  = std.debug.print;
const WINAPI = std.os.windows.WINAPI;

const aio = @import("audio.zig");

// Constants that zigwin32/zig-opengl doesn't provide

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;

const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_ACCELERATION_ARB = 0x2003;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_DEPTH_BITS_ARB = 0x2022;
const WGL_STENCIL_BITS_ARB = 0x2023;
const WGL_FULL_ACCELERATION_ARB = 0x2027;
const WGL_TYPE_RGBA_ARB = 0x202B;

var gl_library: w32.HINSTANCE = undefined;

fn get_string(s: u32) [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(w32.glGetString(s))));
}

fn get_proc_address(comptime cxt: @TypeOf(null), entry_point: [:0]const u8) ?*anyopaque {
    // We don't use this value but the OpenGL loader requires it for the function it so /shrug
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

    var audio = aio.AudioEngine.init(gpa.allocator());
    defer audio.deinit();

    const sound_path = "D:\\projects\\moon\\res\\test_audio.wav";
    const sound_handle = audio.load_sound(sound_path);

    audio.play_sound(sound_handle);

    // Window creation

    const module_handle = w32.GetModuleHandleW(null) orelse unreachable;
    const class_name = w32.L("MOON");

    const window_class = w32.WNDCLASSEXW {
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

    const handle = w32.CreateWindowExW(
        @enumFromInt(0), 
        class_name,
        title, 
        w32.WS_OVERLAPPEDWINDOW, 
        x, y, w, h, 
        null, null, module_handle, null
        ) orelse return error.WindowCreationFailed;

    // Loading OpenGL

    var pfd = std.mem.zeroes(w32.PIXELFORMATDESCRIPTOR);
    pfd.nVersion     = 1;
    pfd.nSize        = @sizeOf(w32.PIXELFORMATDESCRIPTOR);
    pfd.dwFlags      = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER;
    pfd.iPixelType   = w32.PFD_TYPE_RGBA;
    pfd.cColorBits   = 32;
    pfd.cDepthBits   = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType   = w32.PFD_MAIN_PLANE;

    const hdc = w32.GetDC(handle) orelse @panic("Unable to access DC");
    defer _ = w32.ReleaseDC(handle, hdc);

    const quasi_format = w32.ChoosePixelFormat(hdc, &pfd);
    _ = w32.SetPixelFormat(hdc, quasi_format, &pfd);

    const quasi_context = w32.wglCreateContext(hdc) orelse @panic("Couldn't create WGL context");
    _ = w32.wglMakeCurrent(hdc, quasi_context);
    defer _ = w32.wglDeleteContext(quasi_context);

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

    if (wglChoosePixelFormatARB(hdc, &pfd_attributes, null, 1, @as([*]c_int, @ptrCast(&format)), &format_count) == 0 
        or format_count == 0) {
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
        print("Shader Error: {s}\n", .{shader_log});
    }

    const vertex_shader = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vertex_shader, 1, @as([*c]const [*c]const u8, @ptrCast(&vertex_source)), null);
    gl.compileShader(vertex_shader);

    gl.getShaderiv(vertex_shader, gl.COMPILE_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(vertex_shader, 512, 0, &shader_log);
        print("Shader Error: {s}\n", .{shader_log});
    }

    const shader = gl.createProgram();
    gl.attachShader(shader, vertex_shader);
    gl.attachShader(shader, fragment_shader);
    gl.linkProgram(shader);

    gl.getProgramiv(shader, gl.LINK_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(shader, 512, 0, &shader_log);
        print("Shader Error: {s}\n", .{shader_log});
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
