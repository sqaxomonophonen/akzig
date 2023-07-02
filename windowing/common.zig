// LICENSE: see bottom of file

const std = @import("std");

pub const MAX_CURSORS = 1 << 10;

pub const WindowingAPI = enum(u8) {
    x11,
    //wayland,
    windows,
    //cocoa,
};

pub const GraphicsAPI = enum(u8) {
    gl3,
    //vk,
    //dx11,
    //dx12,
    //metal,
};

pub const WindowingAndGraphicsAPI = struct {
    windowing: WindowingAPI,
    graphics: GraphicsAPI,
};

pub const SystemCursor = enum {
    default,
    hand,
    h_arrow,
    v_arrow,
    cross,
    text,
};

// event keysym is mixed unicode/specials; use @enumToInt() for compares
pub const KeySym = enum(u32) {
    // some common ascii mappings
    tab = '\t',
    ret = '\r',
    escape = '\x1b',
    backspace = '\x08',
    space = ' ',

    SPECIAL_BEGIN = 1 << 24, // safely outside of unicode's 21-bit codepoint range
    insert,
    delete,
    home,
    end,
    left,
    up,
    right,
    down,
    page_up,
    page_down,
    print,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_os,
    right_os,
};

pub const Button = enum {
    LEFT,
    MIDDLE,
    RIGHT,
};

pub const WindowId = u32;

pub const Event = struct {
    window_id: ?WindowId,
    event: union(enum) {
        motion: struct {
            x: f32,
            y: f32,
        },
        button: struct {
            which: Button,
            pressed: bool,
            x: f32,
            y: f32,
        },
        key: struct {
            pressed: bool,
            keysym: ?u32,
            codepoint: ?u32,
        },
        enter: void,
        leave: void,
        focus: void,
        unfocus: void,
        window_close: void,
    },
};

pub const WindowOptions = struct {
    width: u31 = 640,
    height: u31 = 480,
    title: []const u8 = "Window",
};

pub const APIRegistrar = struct {
    const Self = @This();

    apis: *[]WindowingAndGraphicsAPI,
    windowing_api: ?WindowingAPI = null,

    pub fn register(self: *Self, graphics_api: GraphicsAPI) void {
        const windowing_api = self.windowing_api orelse std.debug.panic("no windowing api; was self.with_windowing_api() called", .{});
        if (self.apis.len == 0) unreachable;
        (self.apis.*)[0] = .{ .windowing = windowing_api, .graphics = graphics_api };
        self.apis.* = (self.apis.*)[1..];
    }

    pub fn with_windowing_api(self: *Self, windowing_api: WindowingAPI) *Self {
        self.windowing_api = windowing_api;
        return self;
    }
};

pub fn mk_api_registrar(apis: *[]WindowingAndGraphicsAPI) APIRegistrar {
    return .{
        .apis = apis,
    };
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
