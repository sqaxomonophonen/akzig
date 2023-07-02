// LICENSE: see bottom of file

const std = @import("std");
const panic = std.debug.panic;
const builtin = @import("builtin");
const util = @import("windowing/util.zig");
const common = @import("windowing/common.zig");

pub const KeySym = common.KeySym;

const Error = error{
    TODO,
    NotInitialized,
    MissingTitle,
    UnhandledWindowingAndGraphicsAPI,
    NoAPIs,
    UnavailableAPI,
};

const on_x11_platform = switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd, .dragonfly => true,
    else => false,
};
//const on_wayland_platform = on_x11_platform; // I guess?
const on_windows = (builtin.os.tag == .windows);

pub const CompileOptions = struct {
    with_x11: bool = on_x11_platform,
    with_windows: bool = on_windows,
    //with_wayland: bool = on_wayland_platform,

    pub fn bless(comptime compile_options: CompileOptions) type {
        return make_package_struct(compile_options);
    }
};

fn make_package_struct(comptime compile_options: CompileOptions) type {
    const x11 = if (compile_options.with_x11) @import("windowing/x11.zig") else void;
    const windows = if (compile_options.with_windows) @import("windowing/windows.zig") else void;

    const BackendWindow = util.remove_union_voids(union {
        x11: if (compile_options.with_x11) x11.Window else void,
        windows: if (compile_options.with_windows) windows.Window else void,
    });

    const Window = struct {
        free: bool = false,
        x: u31,
        y: u31,
        width: u31,
        height: u31,
        title: []const u8,
        backend_window: BackendWindow,
    };
    const WindowList = std.ArrayList(Window);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        have_x11: bool,
        have_windows: bool,
        selected_api: ?common.WindowingAndGraphicsAPI,
        available_apis: []common.WindowingAndGraphicsAPI,
        windows: WindowList,
        current_render_window_id: ?common.WindowId = null,

        pub fn open(allocator: std.mem.Allocator) !Self {
            var apis = try allocator.alloc(common.WindowingAndGraphicsAPI, 1 << 8);
            var p = apis;
            var rr = common.mk_api_registrar(&p);
            var rrp = &rr;
            const have_x11 = if (compile_options.with_x11) x11.probe(rrp.with_windowing_api(.x11)) else false;
            const have_windows = if (compile_options.with_windows) windows.probe(rrp.with_windowing_api(.windows)) else false;
            const n_apis = apis.len - p.len;
            const r = Self{
                .allocator = allocator,
                .available_apis = apis[0..n_apis],
                .have_x11 = have_x11,
                .have_windows = have_windows,
                .selected_api = null,
                .windows = WindowList.init(allocator),
            };
            return r;
        }

        pub fn find_window_id(self: *const Self, cmp: anytype) ?common.WindowId {
            for (self.windows.items, 0..) |w, i| {
                if (w.free) continue;
                if (cmp.match(w.backend_window)) {
                    return @intCast(i);
                }
            }
            return null;
        }

        fn alloc_window(self: *Self, w: Window) !common.WindowId {
            const window_id_usize = brk: {
                for (self.windows.items, 0..) |*window, i| {
                    if (window.*.free) {
                        window.* = w;
                        break :brk i;
                    }
                }
                const i = self.windows.items.len;
                try self.windows.append(w);
                break :brk i;
            };
            return @intCast(window_id_usize);
        }

        pub fn open_window(self: *Self, options: common.WindowOptions) !common.WindowId {
            if (options.title.len == 0) return error.MissingTitle;
            const api = self.selected_api orelse return error.NotInitialized;

            const backend_window: BackendWindow = switch (api.windowing) {
                .x11 => if (compile_options.with_x11) .{ .x11 = try x11.open_window(options) } else unreachable,
                .windows => if (compile_options.with_windows) .{ .windows = try windows.open_window(options) } else unreachable,
            };

            return try self.alloc_window(.{
                .x = 0,
                .y = 0,
                .width = options.width,
                .height = options.height,
                .title = options.title, // TODO copy?
                .backend_window = backend_window,
            });
        }

        pub fn poll_event(self: *Self) ?common.Event {
            const api = self.selected_api orelse return null;
            return switch (api.windowing) {
                .x11 => if (compile_options.with_x11) x11.poll_event(self) else unreachable,
                .windows => if (compile_options.with_windows) windows.poll_event(self) else unreachable,
            };
        }

        pub fn begin_render(self: *Self, window_id: common.WindowId) bool {
            const api = self.selected_api orelse return false;
            var window = &self.windows.items[window_id];
            if (window.free) panic("using freed window", .{});
            if (self.current_render_window_id != null) panic("already rendering window {d}", .{self.current_render_window_id.?});
            self.current_render_window_id = window_id;
            switch (api.windowing) {
                .x11 => if (compile_options.with_x11) (x11.begin_render(window) catch return false) else unreachable,
                .windows => if (compile_options.with_windows) (windows.begin_render(window) catch return false) else unreachable,
            }
            return true;
        }

        pub fn end_render(self: *Self) void {
            if (self.current_render_window_id == null) panic("not rendering any window", .{});
            const api = self.selected_api orelse unreachable;
            var window = &self.windows.items[self.current_render_window_id.?];
            if (window.free) panic("using freed window", .{});
            switch (api.windowing) {
                .x11 => if (compile_options.with_x11) x11.end_render(window) else unreachable,
                .windows => if (compile_options.with_windows) windows.end_render(window) else unreachable,
            }
            self.current_render_window_id = null;
        }

        pub fn set_api(self: *Self, api_to_set: common.WindowingAndGraphicsAPI) !void {
            if (!brk: {
                for (self.available_apis) |api| {
                    if (util.shallow_eql(api, api_to_set)) {
                        break :brk true;
                    }
                }
                break :brk false;
            }) return error.UnavailableAPI;

            switch (api_to_set.windowing) {
                .x11 => if (compile_options.with_x11) try x11.open(api_to_set.graphics) else unreachable,
                .windows => if (compile_options.with_windows) try windows.open(api_to_set.graphics) else unreachable,
            }

            self.selected_api = api_to_set;
        }

        pub fn set_best_api(self: *Self) !void {
            if (self.available_apis.len == 0) return error.NoAPIs;
            try self.set_api(self.available_apis[0]);
        }
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
