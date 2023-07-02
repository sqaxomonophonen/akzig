// LICENSE: see bottom of file

const std = @import("std");
const os = std.os;
const fs = std.fs;
const print = std.debug.print;

const defines_str =
    \\XK_MISCELLANY
    \\XK_XKB_KEYS
    \\XK_LATIN1
    \\XK_LATIN2
    \\XK_LATIN3
    \\XK_LATIN4
    \\XK_LATIN8
    \\XK_LATIN9
    \\XK_CAUCASUS
    \\XK_GREEK
    \\XK_KATAKANA
    \\XK_ARABIC
    \\XK_CYRILLIC
    \\XK_HEBREW
    \\XK_THAI
    \\XK_KOREAN
    \\XK_ARMENIAN
    \\XK_GEORGIAN
    \\XK_VIETNAMESE
    \\XK_CURRENCY
    \\XK_MATHEMATICAL
    \\XK_BRAILLE
    \\XK_SINHALA
;

const header_path = "/usr/include/X11/keysymdef.h";

fn emit_sym_to_codepoint(out: *std.fs.File.Writer) !void {
    var file = try std.fs.cwd().openFile(header_path, .{});
    defer file.close();
    var gba = std.heap.GeneralPurposeAllocator(.{}){};
    var data = try file.reader().readAllAlloc(gba.allocator(), 1 << 24);

    var tokenizer = std.c.Tokenizer{ .buffer = data };

    var state: enum {
        IGNORE_REST_OF_LINE,
        INIT,
        H0,
        DEFINE0,
        DEFINE1,
        DEFINE2,
        IFDEF,
    } = .INIT;

    var xk_name: []const u8 = undefined;
    var xk_sym: u32 = undefined;

    var defines_it = std.mem.splitScalar(@TypeOf(defines_str[0]), defines_str, '\n');

    var block_is_visible: bool = false;

    var symset = std.HashMap(u32, bool, struct {
        pub fn hash(_: @This(), s: u32) u64 {
            return s;
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    }, 80).init(gba.allocator());
    defer symset.deinit();

    blk: while (true) {
        const t = tokenizer.next();

        switch (t.id) {
            .Eof => break :blk,
            else => {},
        }

        switch (state) {
            .IGNORE_REST_OF_LINE => {},
            .INIT => {
                switch (t.id) {
                    .Hash => state = .H0,
                    else => state = .IGNORE_REST_OF_LINE,
                }
            },
            .H0 => {
                switch (t.id) {
                    .Keyword_define => state = .DEFINE0,
                    .Keyword_ifdef => state = .IFDEF,
                    else => state = .IGNORE_REST_OF_LINE,
                }
            },
            .IFDEF => {
                switch (t.id) {
                    .Identifier => {
                        defines_it.reset();
                        block_is_visible = false;
                        while (defines_it.next()) |name| {
                            const ident = data[t.start..t.end];
                            if (std.mem.eql(@TypeOf(name[0]), name, ident)) {
                                block_is_visible = true;
                                break;
                            }
                        }
                        state = .IGNORE_REST_OF_LINE;
                    },
                    else => state = .IGNORE_REST_OF_LINE,
                }
            },
            .DEFINE0 => {
                if (!block_is_visible) {
                    state = .IGNORE_REST_OF_LINE;
                } else {
                    switch (t.id) {
                        .Identifier => {
                            xk_name = data[t.start..t.end];
                            state = .DEFINE1;
                        },
                        else => state = .IGNORE_REST_OF_LINE,
                    }
                }
            },
            .DEFINE1 => {
                switch (t.id) {
                    .IntegerLiteral => {
                        xk_sym = try std.fmt.parseInt(@TypeOf(xk_sym), data[t.start..t.end], 0);
                        state = .DEFINE2;
                    },
                    else => state = .IGNORE_REST_OF_LINE,
                }
            },
            .DEFINE2 => {
                state = .IGNORE_REST_OF_LINE;
                switch (t.id) {
                    .MultiLineComment => {
                        const txt = data[t.start..t.end];
                        const prefix = "U+";
                        if (std.mem.indexOf(@TypeOf(txt[0]), txt, prefix)) |idx0| {
                            const tail0 = txt[idx0 + 2 ..];

                            if (std.mem.indexOfScalar(@TypeOf(tail0[0]), tail0, ' ')) |idx1| {
                                const codepoint_hexstr = tail0[0..idx1];
                                var codepoint: u32 = 0;
                                codepoint = try std.fmt.parseInt(@TypeOf(codepoint), codepoint_hexstr, 16);

                                const tail1 = tail0[idx1..];
                                if (std.mem.indexOf(@TypeOf(tail1[0]), tail1, "*/")) |idx2| {
                                    const comment = std.mem.trimRight(@TypeOf(tail1[0]), tail1[0..idx2], " ");
                                    if (!symset.contains(xk_sym)) {
                                        try symset.put(xk_sym, true);
                                        if (xk_sym >= 0x100) { // below 0x100 is a 1:1 map
                                            try out.print("        0x{x:0>7} => 0x{x:0>4}, // {s} :{s}\n", .{ xk_sym, codepoint, xk_name, comment });
                                        }
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            },
        }

        if (state == .IGNORE_REST_OF_LINE and t.id == .Nl) {
            state = .INIT;
        }
    }
}

pub fn main() !void {
    const dst = "../windowing/x11/sym2codepoint.zig";
    var file = try fs.cwd().createFile(dst, .{});
    defer file.close();
    var w = file.writer();

    try w.writeAll(
        \\// AUTO-GENERATED; DO NOT EDIT (change `codegen_x11_sym2codepoint.zig` instead)
        \\// LICENSE: see bottom of file
        \\
    );

    try w.writeAll(
        \\pub fn map_sym_to_codepoint(sym: u32) ?u32 {
        \\    return switch (sym) {
        \\
    );

    try emit_sym_to_codepoint(&w);

    try w.writeAll(
        \\        else => null,
        \\    };
        \\}
        \\
        \\// ----------------------------------------------------------------------------
        \\// This software is available under 2 licenses -- choose whichever you prefer.
        \\// ----------------------------------------------------------------------------
        \\// ALTERNATIVE A - MIT License
        \\// Copyright (c) 2023 Anders Kaare Straadt
        \\// Permission is hereby granted, free of charge, to any person obtaining a copy
        \\// of this software and associated documentation files (the “Software”), to
        \\// deal in the Software without restriction, including without limitation the
        \\// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
        \\// sell copies of the Software, and to permit persons to whom the Software is
        \\// furnished to do so, subject to the following conditions:
        \\// The above copyright notice and this permission notice shall be included in
        \\// all copies or substantial portions of the Software.
        \\// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        \\// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        \\// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        \\// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        \\// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
        \\// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
        \\// IN THE SOFTWARE.
        \\// ----------------------------------------------------------------------------
        \\// ALTERNATIVE B - Public Domain (www.unlicense.org)
        \\// This is free and unencumbered software released into the public domain.
        \\// Anyone is free to copy, modify, publish, use, compile, sell, or distribute
        \\// this software, either in source code form or as a compiled binary, for any
        \\// purpose, commercial or non-commercial, and by any means.
        \\// In jurisdictions that recognize copyright laws, the author or authors of
        \\// this software dedicate any and all copyright interest in the software to the
        \\// public domain. We make this dedication for the benefit of the public at
        \\// large and to the detriment of our heirs and successors. We intend this
        \\// dedication to be an overt act of relinquishment in perpetuity of all present
        \\// and future rights to this software under copyright law.
        \\// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        \\// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        \\// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
        \\// AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
        \\// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
        \\// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        \\// ----------------------------------------------------------------------------
        \\
    );
    print("CODEGEN {s}\n", .{dst});
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
