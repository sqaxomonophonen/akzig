// LICENSE: see bottom of file

const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const assert = std.debug.assert;

const util = @import("util.zig");
const map_sym_to_codepoint = @import("x11/sym2codepoint.zig").map_sym_to_codepoint;
const common = @import("common.zig");

const Error = error{
    TODO,
    NotInitialized,
    NoThreads,
    NoDisplay,
    NoIM,
    GLXChooseFBConfigFailed,
    GLXNoVisuals,
    GLXNoARBCreateContext,
    GLXCouldNotCreateContext,
    GLXCannotMakeContextCurrent,
};

const c = @cImport({
    @cInclude("locale.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
});

pub const Window = struct {
    window: c.Window,
    ic: c.XIC,
};

var x11: util.make_fnptr_stub_from_c_import(c,
    \\XInitThreads
    \\XOpenDisplay
    \\XRootWindow
    \\XOpenIM
    \\XCreateFontCursor
    \\XCreateWindow
    \\XCreateIC
    \\XStoreName
    \\XMapWindow
    \\XSetWMProtocols
    \\XDestroyWindow
    \\XPending
    \\XNextEvent
    \\XFilterEvent
    \\Xutf8LookupString
    \\XDefineCursor
    \\XCreatePixmapCursor
    \\XFreePixmap
    \\XFree
    \\XCreateColormap
    \\XAllocColor
    \\XSetErrorHandler
    \\XSync
    \\XInternAtom
    \\XSetICFocus
    \\XUnsetICFocus
    \\XLookupKeysym
) = undefined;

var glx: util.make_fnptr_stub_from_c_import(c,
    \\glXChooseFBConfig
    \\glXGetVisualFromFBConfig
    \\glXGetFBConfigAttrib
    \\glXGetProcAddress
    \\glXQueryExtensionsString
    \\glXDestroyContext
    \\glXMakeCurrent
    \\glXSwapBuffers
) = undefined;

var gl0: util.make_fnptr_stub_from_c_import(c,
    \\glViewport
    \\glClearColor
    \\glClear
) = undefined;

var probe_result: ?bool = null;
var opened: bool = false;
var libx11: ?std.DynLib = null;
var libglx: ?std.DynLib = null;
var display: ?*c.Display = null;
var screen: c_int = 0;
var visual_info: ?*c.XVisualInfo = null;
var root_window: c.Window = 0;
var im: c.XIM = undefined;
var glctx: c.GLXContext = undefined;
var WM_DELETE_WINDOW: c.Atom = undefined;
var current_graphics_api: ?common.GraphicsAPI = null;

var color_white: c.XColor = undefined;
var color_black: c.XColor = undefined;
var colormap: c.Colormap = undefined;

const Cursor = struct {
    in_use: bool = false,
    cursor: c.Cursor = 0,
};
var cursors = [_]Cursor{.{}} ** common.MAX_CURSORS;

// set this to true if you think [ctrl]+[h] should be backspace and not
// [ctrl]+[h] you long bearded
// motherf^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H^H
const I_HAVE_A_SUFFICIENTLY_LONG_BEARD = false; // TODO how to make this a compile option? :)

fn probe_x11() bool {
    _ = std.os.getenv("DISPLAY") orelse {
        std.log.info("no x11 (no $DISPLAY)", .{});
        return false;
    };

    const name = "libX11.so";
    libx11 = std.DynLib.open(name) catch {
        std.log.info("no x11 (no {s})", .{name});
        return false;
    };
    x11 = util.runtime_link_with_dynlib(&libx11.?, @TypeOf(x11)) catch {
        std.log.info("no x11 (dynamic link failed)", .{});
        return false;
    };

    return true;
}

fn probe_glx() bool {
    const so = "libGLX.so.0";
    libglx = std.DynLib.open(so) catch {
        std.log.info("no GLX", .{});
        return false;
    };
    glx = util.runtime_link_with_dynlib(&libglx.?, @TypeOf(glx)) catch {
        std.log.info("no GLX (dynamic link failed)", .{});
        return false;
    };
    return true;
}

pub fn probe(registrar: *common.APIRegistrar) bool {
    brk: {
        if (probe_result == null) {
            if (!probe_x11()) {
                probe_result = false;
                break :brk;
            }

            var have_glx = probe_glx();
            if (have_glx) {
                registrar.register(.gl3); // XXX gl version?
            }
            //var have_vk == probe_vk();
            probe_result = have_glx; // and have_vk
        }
    }
    return probe_result.?;
}

fn get_x11_error_code_string(code: c_int) []const u8 {
    return switch (code) {
        c.Success => "everything's okay (error code is: not an error)",
        c.BadRequest => "bad request code",
        c.BadValue => "int parameter out of range",
        c.BadWindow => "parameter not a Window",
        c.BadPixmap => "parameter not a Pixmap",
        c.BadAtom => "parameter not an Atom",
        c.BadCursor => "parameter not a Cursor",
        c.BadFont => "parameter not a Font",
        c.BadMatch => "parameter mismatch",
        c.BadDrawable => "parameter not a Pixmap or Window",
        c.BadAccess => "depending on context: key/button already grabbed; attempt to free an illegal cmap entry; attempt to store into a read-only color map entry; attempt to modify the access control list from other than the local host.",
        c.BadAlloc => "insufficient resources",
        c.BadColor => "no such colormap",
        c.BadGC => "parameter not a GC",
        c.BadIDChoice => "choice not in range or already used",
        c.BadName => "font or color name doesn't exist",
        c.BadLength => "Request length incorrect",
        c.BadImplementation => "server is defective",
        else => "*UNKNOWN*",
    };
}

fn x_error_handler(_: ?*c.Display, ev: ?*c.XErrorEvent) callconv(.C) c_int {
    print("X11 error: {s}\n", .{get_x11_error_code_string(ev.?.*.error_code)});
    return 0;
}

fn add_system_cursor(cursor: common.SystemCursor, shape: c_uint) void {
    var cur = &cursors[@intFromEnum(cursor)];
    assert(!cur.in_use);
    cur.in_use = true;
    cur.cursor = x11.XCreateFontCursor(display, shape);
}

fn gfx_get_attrib(cfg: c.GLXFBConfig, name: c_int) ?c_int {
    var value: c_int = -1;
    if (glx.glXGetFBConfigAttrib(display, cfg, name, &value) != c.Success) {
        std.log.warn("glXGetFBConfigAttrib() failed for {d}", .{name});
        return null;
    } else {
        return value;
    }
}

fn glx_reject_bit_not_set(cfg: c.GLXFBConfig, name: c_int, mask: c_int) ?void {
    const value = gfx_get_attrib(cfg, name) orelse return null;
    if (value & mask == 0) return null;
}

fn glx_reject_ne(cfg: c.GLXFBConfig, name: c_int, expected_value: c_int) ?void {
    const value = gfx_get_attrib(cfg, name) orelse return null;
    if (value != expected_value) return null;
}

fn glx_reject_gt0(cfg: c.GLXFBConfig, name: c_int) ?void {
    const value = gfx_get_attrib(cfg, name) orelse return null;
    if (value > 0) return null;
}

fn glx_dump(cfg: c.GLXFBConfig, comptime name: []const u8) void {
    var value: c_int = 0;
    if (glx.glXGetFBConfigAttrib(display, cfg, @field(c, name), &value) == c.Success) {
        std.log.debug("  {s}: {d}", .{ name, value });
    } else {
        std.log.debug("  {s}: FAILED TO GET", .{name});
    }
}

fn x_free(x: anytype) void {
    _ = x11.XFree(@as(*anyopaque, @ptrCast(x)));
}

fn c_str_to_str(in: [*:0]const u8) []const u8 {
    var ii: ?usize = null;
    var i: usize = 0;
    while (true) {
        if (in[i] == 0) {
            ii = i;
            break;
        }
        i += 1;
    }
    var iii = ii orelse unreachable;
    return in[0..iii];
}

fn is_opengl_extension_supported(str: []const u8, search: []const u8) bool {
    const T = @TypeOf(str[0]);
    var it = std.mem.splitScalar(T, str, ' ');
    while (it.next()) |e| {
        if (std.mem.eql(T, e, search)) return true;
    }
    return false;
}

var opengl_tmp_ctx_error_code: c_int = 0;
fn tmp_ctx_error_handler(_: ?*c.Display, ev: ?*c.XErrorEvent) callconv(.C) c_int {
    opengl_tmp_ctx_error_code = ev.?.*.error_code;
    return 0;
}

pub fn open(graphics_api: common.GraphicsAPI) !void {
    assert(probe_result == true);
    if (opened) return;

    // this inconspicuous boilerplate line seems to have weird and deep
    // implications for keyboard input:
    //   without setlocale():   [compose],[a],[e] => "æ", [compose],[a],[a] => "å", [compose],[o],[a] => no KeyPress event at all
    //   with setlocale():      [compose],[a],[e] => "æ", [compose],[a],[a] => "å", [compose],[o],[a] => "å"
    _ = c.setlocale(c.LC_ALL, "");

    _ = x11.XSetErrorHandler(&x_error_handler);

    if (x11.XInitThreads() == 0) {
        return Error.NoThreads;
    }

    display = x11.XOpenDisplay(null);
    if (display == null) {
        return Error.NoDisplay;
    }

    screen = c.DefaultScreen(display);
    root_window = x11.XRootWindow(display, screen);

    im = x11.XOpenIM(display, null, null, null);
    if (im == null) {
        return Error.NoIM;
    }

    WM_DELETE_WINDOW = x11.XInternAtom(display, "WM_DELETE_WINDOW", c.False);

    add_system_cursor(common.SystemCursor.default, c.XC_left_ptr);
    add_system_cursor(common.SystemCursor.hand, c.XC_hand1);
    add_system_cursor(common.SystemCursor.h_arrow, c.XC_sb_h_double_arrow);
    add_system_cursor(common.SystemCursor.v_arrow, c.XC_sb_v_double_arrow);
    add_system_cursor(common.SystemCursor.cross, c.XC_fleur);
    add_system_cursor(common.SystemCursor.text, c.XC_xterm);

    switch (graphics_api) {
        .gl3 => {
            // find a visual...

            assert(visual_info == null);
            var fb_config: c.GLXFBConfig = null;
            {
                const attrs = [_]c_int{
                    c.GLX_X_RENDERABLE,   c.True,
                    c.GLX_DRAWABLE_TYPE,  c.GLX_WINDOW_BIT,
                    c.GLX_RENDER_TYPE,    c.GLX_RGBA_BIT,
                    c.GLX_X_VISUAL_TYPE,  c.GLX_TRUE_COLOR,
                    c.GLX_RED_SIZE,       8,
                    c.GLX_GREEN_SIZE,     8,
                    c.GLX_BLUE_SIZE,      8,
                    c.GLX_ALPHA_SIZE,     8,
                    c.GLX_DEPTH_SIZE,     0,
                    c.GLX_STENCIL_SIZE,   8,
                    c.GLX_DOUBLEBUFFER,   c.True,
                    c.GLX_SAMPLE_BUFFERS, 0,
                    c.GLX_SAMPLES,        0,
                    c.None,
                };

                var n: c_int = -1;
                const cs = glx.glXChooseFBConfig(display, screen, &attrs, &n) orelse return error.GLXChooseFBConfigFailed;
                if (n < 0) return error.GLXChooseFBConfigFailed;

                // TODO better visual selection? there can be "hard
                // requirements" for a visual, but when several visuals meet
                // these, it still makes sense to select the visual having the
                // "least features" (I had a bug in this code where it
                // defaulted to the last visual instead of the first valid one;
                // this visual performs noticeably worse than the first
                // visual). one idea is to assign "penalty weights" to various
                // fields, and then select the "lightest" one. e.g. it seems
                // more important to reject multisampling than accumulation
                // buffers?

                var first_valid: ?usize = null;
                var vis: ?*c.XVisualInfo = null;
                for (0..@intCast(n)) |i| {
                    if (vis != null) x_free(vis);

                    const ci = cs[i];
                    vis = glx.glXGetVisualFromFBConfig(display, ci) orelse continue;

                    // hard requirements
                    glx_reject_bit_not_set(ci, c.GLX_DRAWABLE_TYPE, c.GLX_WINDOW_BIT) orelse continue;
                    glx_reject_ne(ci, c.GLX_X_RENDERABLE, c.True) orelse continue;
                    glx_reject_ne(ci, c.GLX_X_VISUAL_TYPE, c.GLX_TRUE_COLOR) orelse continue;

                    if (first_valid == null) first_valid = i;

                    std.log.debug("=========== considering visual #{d} ===========", .{i});
                    glx_dump(ci, "GLX_X_RENDERABLE");
                    glx_dump(ci, "GLX_DRAWABLE_TYPE");
                    glx_dump(ci, "GLX_RENDER_TYPE");
                    glx_dump(ci, "GLX_X_VISUAL_TYPE");
                    glx_dump(ci, "GLX_RED_SIZE");
                    glx_dump(ci, "GLX_GREEN_SIZE");
                    glx_dump(ci, "GLX_BLUE_SIZE");
                    glx_dump(ci, "GLX_ALPHA_SIZE");
                    glx_dump(ci, "GLX_ACCUM_RED_SIZE");
                    glx_dump(ci, "GLX_ACCUM_GREEN_SIZE");
                    glx_dump(ci, "GLX_ACCUM_BLUE_SIZE");
                    glx_dump(ci, "GLX_ACCUM_ALPHA_SIZE");
                    glx_dump(ci, "GLX_DEPTH_SIZE");
                    glx_dump(ci, "GLX_STENCIL_SIZE");
                    glx_dump(ci, "GLX_DOUBLEBUFFER");
                    glx_dump(ci, "GLX_SAMPLE_BUFFERS");
                    glx_dump(ci, "GLX_SAMPLES");

                    // soft-reject multisampling visuals
                    glx_reject_gt0(ci, c.GLX_SAMPLE_BUFFERS) orelse continue;
                    glx_reject_gt0(ci, c.GLX_SAMPLES) orelse continue;

                    //glx_reject_gt0(ci, c.GLX_ACCUM_RED_SIZE) orelse continue;
                    //glx_reject_gt0(ci, c.GLX_ACCUM_GREEN_SIZE) orelse continue;
                    //glx_reject_gt0(ci, c.GLX_ACCUM_BLUE_SIZE) orelse continue;
                    //glx_reject_gt0(ci, c.GLX_ACCUM_ALPHA_SIZE) orelse continue;

                    visual_info = vis;
                    fb_config = ci;
                    break;
                }

                if (fb_config == null) {
                    if (vis != null) x_free(vis);
                    if (first_valid == null) {
                        return error.GLXNoVisuals;
                    } else {
                        // we only reject FB configs with unwanted features, but if
                        // all are rejects, just choose the first valid one
                        visual_info = glx.glXGetVisualFromFBConfig(display, cs[first_valid.?]);
                        fb_config = cs[first_valid.?];
                    }
                }

                x_free(cs);
            }

            { // set colors
                color_white.red = 0xffff;
                color_white.green = 0xffff;
                color_white.blue = 0xffff;

                color_black.red = 0;
                color_black.green = 0;
                color_black.blue = 0;

                colormap = x11.XCreateColormap(display, root_window, visual_info.?.*.visual, c.AllocNone);
                _ = x11.XAllocColor(display, colormap, &color_white);
                _ = x11.XAllocColor(display, colormap, &color_black);
            }

            { // create GL context
                const extensions = glx.glXQueryExtensionsString(display, screen);

                if (!is_opengl_extension_supported(c_str_to_str(extensions), "GLX_ARB_create_context")) {
                    return error.GLXNoARBCreateContext;
                }

                opengl_tmp_ctx_error_code = 0;
                const old_handler = x11.XSetErrorHandler(&tmp_ctx_error_handler);

                const attrs = [_]c_int{
                    c.GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
                    c.GLX_CONTEXT_MINOR_VERSION_ARB, 1,
                    c.None,
                };

                const create_context_fn = @as(c.PFNGLXCREATECONTEXTATTRIBSARBPROC, @ptrCast(glx.glXGetProcAddress("glXCreateContextAttribsARB"))) orelse return error.GLXCouldNotCreateContext;

                const share_context = null;
                const direct = c.True;
                glctx = create_context_fn(display, fb_config, share_context, direct, &attrs);
                _ = x11.XSync(display, c.False);

                if (glctx == null or opengl_tmp_ctx_error_code > 0) {
                    return error.GLXCouldNotCreateContext;
                }
                assert(x11.XSetErrorHandler(old_handler) == &tmp_ctx_error_handler);
            }

            // resolve GL functions
            gl0 = try util.runtime_link_with_get_proc_address(glx.glXGetProcAddress, @TypeOf(gl0));
        },
    }

    current_graphics_api = graphics_api;
    opened = true;
}

pub fn open_window(options: common.WindowOptions) !Window {
    var attrs = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.background_pixmap = c.None;
    attrs.colormap = colormap;
    attrs.border_pixel = 0;
    attrs.event_mask =
        c.StructureNotifyMask | c.EnterWindowMask | c.LeaveWindowMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask | c.KeyPressMask | c.KeyReleaseMask | c.ExposureMask | c.FocusChangeMask | c.PropertyChangeMask | c.VisibilityChangeMask;

    const window = x11.XCreateWindow(display, root_window, 0, 0, options.width, options.height, 0, visual_info.?.*.depth, c.InputOutput, visual_info.?.*.visual, c.CWBorderPixel | c.CWColormap | c.CWEventMask, &attrs);

    const ic = x11.XCreateIC(im, c.XNInputStyle, c.XIMPreeditNothing | c.XIMStatusNothing, c.XNClientWindow, window, c.XNFocusWindow, window, c.None);

    var buffer: [1 << 12]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const title_cstr = try allocator.dupeZ(u8, options.title);

    _ = x11.XStoreName(display, window, title_cstr);
    _ = x11.XMapWindow(display, window);
    _ = x11.XSetWMProtocols(display, window, &WM_DELETE_WINDOW, 1);

    return Window{
        .window = window,
        .ic = ic,
    };
}

fn map_named_keysym(sym: c.KeySym) ?common.KeySym {
    const S = common.KeySym;
    return switch (sym) {
        c.XK_Tab => S.tab,
        c.XK_Return => S.ret,

        c.XK_Escape => S.escape,
        c.XK_BackSpace => S.backspace,
        c.XK_Insert => S.insert,
        c.XK_Delete => S.delete,
        c.XK_Home => S.home,
        c.XK_End => S.end,
        c.XK_Left => S.left,
        c.XK_Up => S.up,
        c.XK_Right => S.right,
        c.XK_Down => S.down,
        c.XK_Page_Up => S.page_up,
        c.XK_Page_Down => S.page_down,
        c.XK_Print => S.print,

        c.XK_F1 => S.f1,
        c.XK_F2 => S.f2,
        c.XK_F3 => S.f3,
        c.XK_F4 => S.f4,
        c.XK_F5 => S.f5,
        c.XK_F6 => S.f6,
        c.XK_F7 => S.f7,
        c.XK_F8 => S.f8,
        c.XK_F9 => S.f9,
        c.XK_F10 => S.f10,
        c.XK_F11 => S.f11,
        c.XK_F12 => S.f12,

        c.XK_Shift_L => S.left_shift,
        c.XK_Shift_R => S.right_shift,
        c.XK_Control_L => S.left_ctrl,
        c.XK_Control_R => S.right_ctrl,
        c.XK_Alt_L => S.left_alt,
        c.XK_Alt_R => S.right_alt,
        c.XK_Super_L => S.left_os,
        c.XK_Super_R => S.right_os,

        else => null,
    };
}

fn map_keysym(sym: c.KeySym) ?u32 {
    if (32 <= sym and sym < 255) {
        // there's an 1:1 relation between keysym/latin-1/unicode in this range
        return @intCast(sym);
    } else {
        if (map_named_keysym(sym)) |ks| {
            return @intFromEnum(ks);
        } else if (sym <= 0xffffffff) {
            const ks = map_sym_to_codepoint(@intCast(sym));
            if (ks != 0) {
                return ks;
            } else {
                return null;
            }
        } else {
            return null;
        }
    }
}

pub fn poll_event(parent: anytype) ?common.Event {
    while (x11.XPending(display) > 0) {
        var xe = mem.zeroes(c.XEvent);
        _ = x11.XNextEvent(display, &xe); // undocumented return value?
        if (x11.XFilterEvent(&xe, c.None) != 0) continue;

        const window_id = parent.find_window_id(struct {
            const Self = @This();
            w: c.Window,
            pub fn match(self: Self, bw: anytype) bool {
                return self.w == bw.x11.window;
            }
        }{ .w = xe.xany.window });

        if (window_id == null) continue; // TODO don't do this if there are non-window events
        var window = &parent.windows.items[window_id.?]; // TODO also don't do this if there are non-window events
        var backend_window = window.backend_window.x11;

        switch (xe.type) {
            c.ConfigureNotify => {
                const ee = xe.xconfigure;
                if (ee.width >= 0 and ee.height >= 0 and (ee.width != window.width or ee.height != window.height)) {
                    print("EV/configure {d}×{d} -> {d}×{d}\n", .{ window.width, window.height, ee.width, ee.height });
                    window.width = @intCast(ee.width);
                    window.height = @intCast(ee.height);
                }
            },
            c.EnterNotify => {
                return .{
                    .window_id = window_id,
                    .event = .{ .enter = {} },
                };
            },
            c.LeaveNotify => {
                return .{
                    .window_id = window_id,
                    .event = .{ .leave = {} },
                };
            },
            c.FocusIn => {
                if (xe.xfocus.mode != c.NotifyGrab and backend_window.ic != null) x11.XSetICFocus(backend_window.ic);
                return .{
                    .window_id = window_id,
                    .event = .{ .focus = {} },
                };
            },
            c.FocusOut => {
                if (xe.xfocus.mode != c.NotifyGrab and backend_window.ic != null) x11.XUnsetICFocus(backend_window.ic);
                return .{
                    .window_id = window_id,
                    .event = .{ .unfocus = {} },
                };
            },
            c.ButtonPress, c.ButtonRelease => {
                const ee = xe.xbutton;
                const which = switch (ee.button) {
                    1 => common.Button.LEFT,
                    2 => common.Button.MIDDLE,
                    3 => common.Button.RIGHT,
                    else => continue, // ignore
                };
                return .{
                    .window_id = window_id,
                    .event = .{ .button = .{
                        .which = which,
                        .pressed = (xe.type == c.ButtonPress),
                        .x = @floatFromInt(ee.x),
                        .y = @floatFromInt(ee.y),
                    } },
                };
            },
            c.MotionNotify => {
                const ee = xe.xmotion;
                return .{
                    .window_id = window_id,
                    .event = .{ .motion = .{
                        .x = @floatFromInt(ee.x),
                        .y = @floatFromInt(ee.y),
                    } },
                };
            },
            c.KeyPress, c.KeyRelease => {
                var ee = xe.xkey;
                const sym = x11.XLookupKeysym(&ee, 0);
                const pressed = (xe.type == c.KeyPress);
                var codepoint: ?u32 = null;

                if (pressed) {
                    var buffer: [8]u8 = undefined;
                    var fallback_sym = mem.zeroes(c.KeySym);
                    var len = x11.Xutf8LookupString(backend_window.ic, &ee, &buffer, buffer.len, &fallback_sym, null);
                    if (len > 0) {
                        if (std.unicode.utf8Decode(buffer[0..@intCast(len)]) catch null) |cp| {
                            if (!I_HAVE_A_SUFFICIENTLY_LONG_BEARD and ((0 < cp and cp < ' ') or cp == 0x7f)) {
                                if (fallback_sym < 0xffffffff) {
                                    codepoint = @intCast(fallback_sym);
                                    // NOTE the use of `fallback_sym`; because it comes
                                    // from Xutf8LookupString() (and NOT
                                    // XLookupKeysym()) it's actually slightly closer
                                    // to being "text input" because [shift]+[a] gives
                                    // fallback_sym='A' with Xutf8LookupString(), but
                                    // fallback_sym='a' with XLookupKeysym(). So this
                                    // weird, crappy inconsistency actually proves
                                    // useful here, "thanks".
                                }
                            } else {
                                codepoint = cp;
                            }
                        }
                    }
                }

                return .{
                    .window_id = window_id,
                    .event = .{
                        .key = .{
                            .pressed = pressed,
                            .keysym = map_keysym(sym),
                            .codepoint = codepoint,
                        },
                    },
                };
            },
            c.ClientMessage => {
                if (xe.xclient.data.l[0] == WM_DELETE_WINDOW) {
                    return .{
                        .window_id = window_id,
                        .event = .{ .window_close = {} },
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn begin_render(window: anytype) !void {
    const api = current_graphics_api orelse return error.NotInitialized;
    switch (api) {
        .gl3 => {
            if (glx.glXMakeCurrent(display, window.backend_window.x11.window, glctx) != c.True) {
                return error.GLXCannotMakeContextCurrent;
            }
            gl0.glViewport(0, 0, window.width, window.height);
            gl0.glClearColor(0.0, 0.3, 0.0, 1.0);
            gl0.glClear(c.GL_COLOR_BUFFER_BIT);
        },
    }
}

pub fn end_render(window: anytype) void {
    switch (current_graphics_api orelse unreachable) {
        .gl3 => {
            glx.glXSwapBuffers(display, window.backend_window.x11.window);
        },
    }
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
