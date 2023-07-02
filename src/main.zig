pub const UNICODE = true;

// Imports

const mem =    @import("std").mem;
const print =  @import("std").debug.print;
const WINAPI = @import("std").os.windows.WINAPI;

const gl = @import("gl");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.open_gl;
    usingnamespace @import("win32").graphics.gdi;
};

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

var gl_library: win32.HINSTANCE = undefined;

fn get_string(s: u32) [:0]const u8 {
    return mem.span(@as([*:0]const u8, @ptrCast(win32.glGetString(s))));
}

fn get_proc_address(comptime cxt: @TypeOf(null), entry_point: [:0]const u8) ?*anyopaque {
    _ = cxt;

    if (gl_library != undefined) {
        const T = *const fn (entry_point: [*:0]const u8) ?*anyopaque;

        // Load >1.1 function
        if (win32.GetProcAddress(gl_library, "wglGetProcAddress")) |wglGetProcAddress| {
            if (@as(T, @ptrCast(wglGetProcAddress))(entry_point.ptr)) |ptr| {
                return @constCast(ptr);
            }
        }

        // Load <=1.1 function
        if (win32.GetProcAddress(gl_library, entry_point.ptr)) |ptr| {
            return @constCast(ptr);
        }
    }

    if (win32.wglGetProcAddress(entry_point.ptr)) |ptr| {
        return @constCast(ptr);
    }

    return null;
}

pub fn main() !void {
    // Window creation

    const module_handle = win32.GetModuleHandle(null) orelse unreachable;
    const class_name = win32.L("MOON");

    const window_class = win32.WNDCLASSEX{
        .style = win32.WNDCLASS_STYLES.initFlags(.{ .OWNDC = 1, .HREDRAW = 1, .VREDRAW = 1 }),
        .lpfnWndProc = win32_callback,
        .cbSize = @sizeOf(win32.WNDCLASSEX),
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
    if (win32.RegisterClassEx(&window_class) == 0) {
        return error.WindowCreationFailed;
    }

    var rect = win32.RECT{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    _ = win32.AdjustWindowRectEx(&rect, win32.WS_OVERLAPPEDWINDOW, 0, @enumFromInt(0));
    const x = win32.CW_USEDEFAULT;
    const y = win32.CW_USEDEFAULT;
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;

    const title = win32.L("Moon");

    const handle = win32.CreateWindowEx(@enumFromInt(0), class_name, title, win32.WS_OVERLAPPEDWINDOW, x, y, w, h, null, null, module_handle, null) 
        orelse return error.WindowCreationFailed;

    // Loading OpenGL

    const pfd = win32.PIXELFORMATDESCRIPTOR{
        .nVersion = 1,
        .nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR),
        .dwFlags = win32.PFD_DRAW_TO_WINDOW | win32.PFD_SUPPORT_OPENGL | win32.PFD_DOUBLEBUFFER,
        .iPixelType = win32.PFD_TYPE_RGBA,
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
        .iLayerType = win32.PFD_MAIN_PLANE,
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const hdc = win32.GetDC(handle) orelse @panic("Unable to access DC");
    defer _ = win32.ReleaseDC(handle, hdc);

    const quasi_format = win32.ChoosePixelFormat(hdc, &pfd);
    _ = win32.SetPixelFormat(hdc, quasi_format, &pfd);

    const quasi_context = win32.wglCreateContext(hdc) orelse @panic("Couldn't create WGL context");
    _ = win32.wglMakeCurrent(hdc, quasi_context);
    errdefer _ = win32.wglDeleteContext(quasi_context);

    const wglChoosePixelFormatARB = @as(
        *const fn (
            hdc: win32.HDC,
            piAttribIList: ?[*:0]const c_int,
            pfAttribFList: ?[*:0]const f32,
            nMaxFormats: c_uint,
            piFormats: [*]c_int,
            nNumFormats: *c_uint,
        ) callconv(WINAPI) win32.BOOL,
        @ptrCast(win32.wglGetProcAddress("wglChoosePixelFormatARB") orelse return error.InvalidOpenGL),
    );

    const wglCreateContextAttribsARB = @as(
        *const fn (
            hdc: win32.HDC,
            hshareContext: ?win32.HGLRC,
            attribList: ?[*:0]const c_int,
        ) callconv(WINAPI) ?win32.HGLRC,
        @ptrCast(win32.wglGetProcAddress("wglCreateContextAttribsARB") orelse return error.InvalidOpenGL),
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

    if (wglChoosePixelFormatARB(hdc, &pfd_attributes, null, 1, @as([*]c_int, @ptrCast(&format)), &format_count) == win32.FALSE or format_count == 0) {
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
    errdefer _ = win32.wglDeleteContext(context);

    if (win32.wglMakeCurrent(hdc, context) == win32.FALSE) {
        return error.InvalidOpenGL;
    }

    gl_library = win32.LoadLibrary(win32.L("opengl32.dll")) orelse @panic("Can't find opengl32.dll");
    try gl.load(null, get_proc_address);

    _ = win32.ShowWindow(handle, win32.SW_SHOW);

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
        var msg: win32.MSG = undefined;
        while (win32.PeekMessage(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            if (msg.message == win32.WM_QUIT) {
                running = false;
            } else {
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessage(&msg);
            }
        }

        gl.clearColor(1.0, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.useProgram(shader);
        gl.bindVertexArray(VAO);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        _ = win32.SwapBuffers(hdc);
    }
}

fn win32_callback(hwnd: win32.HWND, uMsg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    var result: win32.LRESULT = 0;

    switch (uMsg) {
        win32.WM_CLOSE, win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
        },

        else => {
            result = win32.DefWindowProc(hwnd, uMsg, wParam, lParam);
        },
    }

    return result;
}
