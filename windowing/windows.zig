// LICENSE: see bottom of file

const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const windows = std.os.windows;
const WINAPI = windows.WINAPI;
const user32 = windows.user32;
const gdi32 = windows.gdi32;
const util = @import("util.zig");

const Error = error{
    FailedToGetModuleHandle,
    FailedToRegisterClass,
    FailedToCreateDummyWindow,
    FailedToChoosePixelFormat,
    FailedToCreateWindow,
    WGLFailedToCreateDummyContext,
    WGLFailedToMakeDummyContextCurrent,
    WGLNoCreateContextAttribsARB,
};

const common = @import("common.zig");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", {});
    @cInclude("windows.h");
    //@cInclude("windowsx.h");
    @cInclude("wingdi.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/wgl.h");
});

fn WMAPTYPE(comptime T: type) type {
    return switch (T) {
        c.HDC => ?windows.HDC,
        c.HGLRC => ?windows.HGLRC,
        c.LPPIXELFORMATDESCRIPTOR => ?*const gdi32.PIXELFORMATDESCRIPTOR,
        else => T,
    };
}

fn WCALLRET(comptime FT: type) type {
    return WMAPTYPE(util.fn_ptr_return_type(FT));
}

// calls `fn_ptr` with `args`, but function param types are rewritten to match
// those used in `std.os.windows`; new mappings can be added to WMAPTYPE; this
// makes it easier to mix user32/gdi32/etc32 wrapper calls with @cImport-calls;
// it generally seems hard to fix this with casts at the callsite. that is,
// c.HDC and windows.HDC are different types, but you can use both in the
// WINAPI prototype, and the compiler will call the function correctly. but it
// seems hard to cast e.g. windows.HDC to c.HDC
fn WCALL(fn_ptr: anytype, args: anytype) WCALLRET(@TypeOf(fn_ptr)) {
    comptime var FX: type = undefined;
    comptime {
        const F = @TypeOf(fn_ptr);
        const FT = @typeInfo(F);
        if (FT != .Pointer) @compileError("not a Pointer (expecting function pointer)");
        const FTT = @typeInfo(FT.Pointer.child);
        if (FTT != .Fn) @compileError("not a Fn");

        const params = FTT.Fn.params;

        var new_params: [params.len]std.builtin.Type.Fn.Param = .{};
        var i: usize = 0;
        for (params) |param| {
            var pc = param;
            pc.type = WMAPTYPE(param.type.?);
            new_params[i] = pc;
            i += 1;
        }

        var FXTT = FTT;
        FXTT.Fn.params = &new_params;
        FXTT.Fn.return_type = WCALLRET(F);
        var FXT = FT;
        FXT.Pointer.child = @Type(FXTT);
        FX = @Type(FXT);
    }
    return @call(.auto, @as(FX, @ptrCast(fn_ptr)), args);
}

pub const Window = struct {
    window: ?windows.HWND,
    hdc: ?windows.HDC,
    cursor_index: u32 = @intFromEnum(common.SystemCursor.default),
};

var libopengl32: ?std.DynLib = null;

var wgl0: util.make_fnptr_stub_from_c_import(c,
    \\wglCreateContext
    \\wglDeleteContext
    \\wglMakeCurrent
    \\wglGetProcAddress
) = undefined;

var module_handle: c.HMODULE = null;
var standard_window_class = mem.zeroes(c.WNDCLASS);
var dummy_window_class = mem.zeroes(c.WNDCLASS);
var dummy_window: ?Window = null;
var dummy_ctx: ?windows.HGLRC = null;
var create_context_attribs_arb: c.PFNWGLCREATECONTEXTATTRIBSARBPROC = undefined;

const Cursor = struct {
    in_use: bool = false,
    cursor: c.HCURSOR = undefined,
};
var cursors = [_]Cursor{.{}} ** common.MAX_CURSORS;

fn probe_opengl() bool {
    const name = "opengl32.dll";
    libopengl32 = std.DynLib.open(name) catch {
        std.log.info("no gl (no {s})", .{name});
        return false;
    };

    wgl0 = util.runtime_link_with_dynlib(&libopengl32.?, @TypeOf(wgl0)) catch return false;

    return true;
}

pub fn probe(registrar: *common.APIRegistrar) bool {
    const have_opengl = probe_opengl();
    if (have_opengl) {
        registrar.register(.gl3); // XXX gl version?
    }
    return have_opengl; // or got_dx11 etc
}

fn wnd_proc(w: ?windows.HWND, msg: c.UINT, w_param: c.WPARAM, l_param: c.LPARAM) callconv(WINAPI) c.LRESULT {
    switch (msg) {
        user32.WM_DESTROY, user32.WM_CLOSE => {
            user32.PostQuitMessage(0);
        },
        else => {},
    }
    return user32.DefWindowProcA(w.?, msg, w_param, l_param);
}

const INTRESOURCE = [*:0]u8; // I think the real should be `*align(1) c_ulong` but LoadCursorA() doesn't like it
fn add_system_cursor(cursor: common.SystemCursor, name: INTRESOURCE) void {
    const hc = c.LoadCursorA(null, name);
    var cur = &cursors[@intFromEnum(cursor)];
    assert(!cur.in_use);
    cur.in_use = true;
    cur.cursor = hc;
}

// this macro fails when used directly :-/ stuff grabbed from winuser.h .. I
// don't think there's a comptime solution, because it seems
// @TypeOf(c.IDC_ARROW), or any attempt to access these unsupported macros is a
// compile error (TODO: a std.c.Tokenizer codegen approach could work)
fn MAKEINTRESOURCE(v: c_ushort) INTRESOURCE {
    return @ptrFromInt(v);
}
const IDC_ARROW = MAKEINTRESOURCE(32512);
const IDC_IBEAM = MAKEINTRESOURCE(32513);
const IDC_WAIT = MAKEINTRESOURCE(32514);
const IDC_CROSS = MAKEINTRESOURCE(32515);
const IDC_UPARROW = MAKEINTRESOURCE(32516);
const IDC_SIZE = MAKEINTRESOURCE(32640);
const IDC_ICON = MAKEINTRESOURCE(32641);
const IDC_SIZENWSE = MAKEINTRESOURCE(32642);
const IDC_SIZENESW = MAKEINTRESOURCE(32643);
const IDC_SIZEWE = MAKEINTRESOURCE(32644);
const IDC_SIZENS = MAKEINTRESOURCE(32645);
const IDC_SIZEALL = MAKEINTRESOURCE(32646);
const IDC_NO = MAKEINTRESOURCE(32648);
const IDC_HAND = MAKEINTRESOURCE(32649);
const IDC_APPSTARTING = MAKEINTRESOURCE(32650);
const IDC_HELP = MAKEINTRESOURCE(32651);
const IDC_PIN = MAKEINTRESOURCE(32671);
const IDC_PERSON = MAKEINTRESOURCE(32672);

fn open_common() !void {
    module_handle = c.GetModuleHandleA(null);
    if (module_handle == null) {
        return error.FailedToGetModuleHandle;
    }

    add_system_cursor(common.SystemCursor.default, IDC_ARROW);
    add_system_cursor(common.SystemCursor.hand, IDC_HAND);
    add_system_cursor(common.SystemCursor.h_arrow, IDC_SIZEWE);
    add_system_cursor(common.SystemCursor.v_arrow, IDC_SIZENS);
    add_system_cursor(common.SystemCursor.cross, IDC_SIZEALL);
    add_system_cursor(common.SystemCursor.text, IDC_IBEAM);

    { // register standard window class (we probably only need one?)
        const wc = &standard_window_class;
        wc.style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_OWNDC;
        wc.lpfnWndProc = @ptrCast(&wnd_proc);
        wc.hInstance = module_handle;
        wc.lpszClassName = "standard_window_class";
        wc.hCursor = cursors[@intFromEnum(common.SystemCursor.default)].cursor;
        if (c.RegisterClassA(wc) == 0) {
            return error.FailedToRegisterClass;
        }
    }

    { // create dummy window (used to get an OpenGL context; XXX is this necessary for all renderers?)
        const wc = &dummy_window_class;
        wc.style = c.CS_OWNDC;
        wc.lpfnWndProc = @ptrCast(&wnd_proc);
        wc.hInstance = module_handle;
        wc.lpszClassName = "dummy_window_class";
        if (c.RegisterClassA(wc) == 0) {
            return error.FailedToRegisterClass;
        }

        {
            const ex_style = user32.WS_EX_OVERLAPPEDWINDOW;
            const style = user32.WS_OVERLAPPEDWINDOW;
            const name = wc.lpszClassName;
            const window = user32.CreateWindowExA(ex_style, name, name, style, 0, 0, 1, 1, null, null, @ptrCast(module_handle), null);
            if (window == null) {
                return error.FailedToCreateDummyWindow;
            }

            _ = user32.ShowWindow(window.?, c.SW_HIDE);
            const hdc = user32.GetDC(window.?);
            if (hdc == null) {
                return error.FailedToCreateDummyWindow;
            }

            dummy_window = .{ .window = window, .hdc = hdc };
        }
    }
}

fn fn_arg_type(comptime f: type, comptime idx: u32) type {
    return @typeInfo(f).Fn.params[idx].type.?;
}

pub fn open(api: common.GraphicsAPI) !void {
    try open_common();

    switch (api) {
        .gl3 => {
            var want = mem.zeroes(gdi32.PIXELFORMATDESCRIPTOR);
            want.nSize = @sizeOf(@TypeOf(want));
            want.nVersion = 1;
            want.dwFlags = c.PFD_SUPPORT_OPENGL | c.PFD_DRAW_TO_WINDOW | c.PFD_DOUBLEBUFFER;
            want.cColorBits = 32;
            want.iPixelType = c.PFD_TYPE_RGBA;

            const pixfmt_index = gdi32.ChoosePixelFormat(dummy_window.?.hdc, &want);
            if (pixfmt_index == 0) {
                return error.FailedToChoosePixelFormat;
            }

            var have = mem.zeroes(gdi32.PIXELFORMATDESCRIPTOR);
            _ = WCALL(&c.DescribePixelFormat, .{ dummy_window.?.hdc, pixfmt_index, @sizeOf(@TypeOf(have)), &have });
            _ = gdi32.SetPixelFormat(dummy_window.?.hdc, pixfmt_index, &have);
            dummy_ctx = WCALL(wgl0.wglCreateContext, .{dummy_window.?.hdc});
            if (dummy_ctx == null) {
                return error.WGLFailedToCreateDummyContext;
            }

            if (WCALL(wgl0.wglMakeCurrent, .{ dummy_window.?.hdc, dummy_ctx }) == 0) {
                return error.WGLFailedToMakeDummyContextCurrent;
            }

            create_context_attribs_arb = @ptrCast(wgl0.wglGetProcAddress("wglCreateContextAttribsARB") orelse {
                return error.WGLNoCreateContextAttribsARB;
            });
        },
    }
}

pub fn open_window(_: common.WindowOptions) !Window {
    const ex_style = user32.WS_EX_OVERLAPPEDWINDOW;
    const style = user32.WS_OVERLAPPEDWINDOW;
    const name = standard_window_class.lpszClassName;
    const window = user32.CreateWindowExA(ex_style, name, name, style, 0, 0, 1, 1, null, null, @ptrCast(module_handle), null);
    if (window == null) {
        return error.FailedToCreateWindow;
    }

    const hdc = user32.GetDC(window.?);
    if (hdc == null) {
        return error.FailedToCreateWindow;
    }

    _ = user32.ShowWindow(window.?, c.SW_SHOW);

    return Window{
        .window = window,
        .hdc = hdc,
    };
}

// GET_X_LPARAM / GET_Y_LPARAM macros (from windowsx.h) are too complex to use as-is
fn get_x_lparam(p: windows.LONG_PTR) f32 {
    //#define LOWORD(l) ((WORD) (((DWORD_PTR) (l)) & 0xffff))
    //#define GET_X_LPARAM(lp) ((int)(short)LOWORD(lp))
    return @floatFromInt(@as(u16, @truncate(@as(usize, @intCast(p)))));
}
fn get_y_lparam(p: windows.LONG_PTR) f32 {
    //#define HIWORD(l) ((WORD) ((((DWORD_PTR) (l)) >> 16) & 0xffff))
    //#define GET_Y_LPARAM(lp) ((int)(short)HIWORD(lp))
    return @floatFromInt(@as(u16, @truncate(@as(usize, @intCast(p)) >> 16)));
}

pub fn poll_event(parent: anytype) ?common.Event {
    while (true) {
        var msg = mem.zeroes(user32.MSG);
        if (user32.PeekMessageA(&msg, null, 0, 0, user32.PM_REMOVE) == 0) return null;

        const window_id = parent.find_window_id(struct {
            const Self = @This();
            w: ?windows.HWND,
            pub fn match(self: Self, bw: anytype) bool {
                return self.w == bw.windows.window;
            }
        }{ .w = msg.hWnd });

        if (window_id == null) continue; // TODO don't do this if there are non-window events
        var window = &parent.windows.items[window_id.?]; // TODO also don't do this if there are non-window events
        var backend_window = window.backend_window.windows;

        switch (msg.message) {
            user32.WM_SETCURSOR => {
                _ = WCALL(&c.SetCursor, .{cursors[backend_window.cursor_index].cursor});
            },

            user32.WM_LBUTTONDOWN, user32.WM_LBUTTONUP, user32.WM_RBUTTONDOWN, user32.WM_RBUTTONUP, user32.WM_MBUTTONDOWN, user32.WM_MBUTTONUP => {
                return .{
                    .window_id = window_id,
                    .event = .{ .button = .{
                        .which = switch (msg.message) {
                            user32.WM_LBUTTONDOWN, user32.WM_LBUTTONUP => common.Button.LEFT,
                            user32.WM_RBUTTONDOWN, user32.WM_RBUTTONUP => common.Button.RIGHT,
                            user32.WM_MBUTTONDOWN, user32.WM_MBUTTONUP => common.Button.MIDDLE,
                            else => unreachable,
                        },
                        .pressed = switch (msg.message) {
                            user32.WM_LBUTTONDOWN, user32.WM_RBUTTONDOWN, user32.WM_MBUTTONDOWN => true,
                            else => false,
                        },
                        .x = get_x_lparam(msg.lParam),
                        .y = get_y_lparam(msg.lParam),
                    } },
                };
            },

            user32.WM_MOUSEMOVE => {
                return .{
                    .window_id = window_id,
                    .event = .{ .motion = .{
                        .x = get_x_lparam(msg.lParam),
                        .y = get_y_lparam(msg.lParam),
                    } },
                };
            },

            user32.WM_KEYDOWN, user32.WM_KEYUP => {
                const pressed = (msg.message == user32.WM_KEYDOWN);
                const S = common.KeySym;
                const wp = msg.wParam;
                const sym: ?S = brk: {
                    const s0 = switch (wp) {
                        c.VK_TAB => S.tab,
                        c.VK_RETURN => S.ret,
                        c.VK_ESCAPE => S.escape,
                        c.VK_SPACE => S.space,
                        c.VK_LEFT => S.left,
                        c.VK_RIGHT => S.right,
                        c.VK_UP => S.up,
                        c.VK_DOWN => S.down,
                        c.VK_INSERT => S.insert,
                        c.VK_DELETE => S.delete,
                        c.VK_HOME => S.home,
                        c.VK_END => S.end,
                        c.VK_PRIOR => S.page_up,
                        c.VK_NEXT => S.page_down,
                        else => null,
                    };
                    if (s0 != null) break :brk s0;

                    if (c.VK_F1 <= wp and wp <= c.VK_F2) {
                        break :brk @enumFromInt(@intFromEnum(S.f1) + (wp - c.VK_F1));
                    }

                    break :brk null;
                };

                if (sym == null) continue;

                return .{
                    .window_id = window_id,
                    .event = .{
                        .key = .{
                            .pressed = pressed,
                            .keysym = @intFromEnum(sym.?),
                            .codepoint = null,
                        },
                    },
                };
            },

            user32.WM_CHAR => {
                const wp = msg.wParam;
                if (0 < wp and wp < 0x10000) {
                    return .{
                        .window_id = window_id,
                        .event = .{
                            .key = .{
                                .pressed = true,
                                .keysym = null, // XXX?
                                .codepoint = @intCast(wp),
                            },
                        },
                    };
                }
            },

            else => {
                _ = user32.TranslateMessage(&msg);
                _ = user32.DispatchMessageA(&msg);
            },
        }
    }
}

pub fn begin_render(_: anytype) !void {
    // TODO
}

pub fn end_render(_: anytype) void {
    // TODO
}

// ----------------------------------------------------------------------------
// This software is available under 2 licenses -- choose whichever you prefer.
// ----------------------------------------------------------------------------
// ALTERNATIVE A - MIT License
// Copyright (c) 2023 Anders Kaare Straadt
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the “Software”), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
// ----------------------------------------------------------------------------
// ALTERNATIVE B - Public Domain (www.unlicense.org)
// This is free and unencumbered software released into the public domain.
// Anyone is free to copy, modify, publish, use, compile, sell, or distribute
// this software, either in source code form or as a compiled binary, for any
// purpose, commercial or non-commercial, and by any means.
// In jurisdictions that recognize copyright laws, the author or authors of
// this software dedicate any and all copyright interest in the software to the
// public domain. We make this dedication for the benefit of the public at
// large and to the detriment of our heirs and successors. We intend this
// dedication to be an overt act of relinquishment in perpetuity of all present
// and future rights to this software under copyright law.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
// AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// ----------------------------------------------------------------------------
