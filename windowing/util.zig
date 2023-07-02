// LICENSE: see bottom of file

const std = @import("std");
const print = std.debug.print;
const panic = std.debug.panic;

pub fn it_len(it: anytype) usize {
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    it.reset();
    return n;
}

pub fn make_fnptr_stub_from_c_import(comptime C: type, comptime ids: []const u8) type {
    var it = std.mem.splitScalar(@TypeOf(ids[0]), ids, '\n');
    const n = it_len(&it);
    var fields: [n]std.builtin.Type.StructField = .{};
    var i: usize = 0;
    while (it.next()) |e| {
        const TF = @TypeOf(&@field(C, e));
        fields[i] = .{
            .name = e,
            .type = TF,
            .default_value = null,
            .alignment = @sizeOf(TF),
            .is_comptime = false,
        };
        i += 1;
    }
    return @Type(std.builtin.Type{ .Struct = .{
        .layout = .Auto,
        .is_tuple = false,
        .fields = &fields,
        .decls = &[0]std.builtin.Type.Declaration{},
    } });
}

pub const LookupLinkError = error{
    MissingFunction,
};

pub fn runtime_link(resolver: anytype, comptime T: type) LookupLinkError!T {
    const fields = @typeInfo(T).Struct.fields;
    var r: T = undefined;
    inline for (fields) |field| {
        const n = field.name.len;
        var name_with_sentinel: [n + 1]u8 = undefined;
        @memcpy(name_with_sentinel[0..n], field.name);
        name_with_sentinel[n] = 0;
        @field(r, field.name) = resolver.resolve(@TypeOf(@field(r, field.name)), name_with_sentinel[0..n :0]) orelse {
            std.log.debug("runtime link failed for [{s}]", .{field.name});
            return LookupLinkError.MissingFunction;
        };
    }
    return r;
}

pub fn runtime_link_with_dynlib(dl: *std.DynLib, comptime T: type) LookupLinkError!T {
    var resolver = struct {
        const Self = @This();
        dl: *std.DynLib,
        pub fn resolve(self: Self, comptime field_type: type, name: [:0]u8) ?field_type {
            return self.dl.lookup(field_type, name);
        }
    }{
        .dl = dl,
    };
    return runtime_link(resolver, T);
}

pub fn runtime_link_with_get_proc_address(get_proc_address: anytype, comptime T: type) LookupLinkError!T {
    var resolver = struct {
        const Self = @This();
        get_proc_address: @TypeOf(get_proc_address),
        pub fn resolve(self: Self, comptime field_type: type, name: [:0]u8) ?field_type {
            return @ptrCast(self.get_proc_address(name) orelse return null);
        }
    }{
        .get_proc_address = get_proc_address,
    };
    return runtime_link(resolver, T);
}

pub fn shallow_eql(a: anytype, b: @TypeOf(a)) bool {
    return switch (@typeInfo(@TypeOf(a))) {
        .Type, .Bool, .Int, .Float, .ComptimeFloat, .ComptimeInt, .EnumLiteral, .Enum, .Fn, .ErrorSet => a == b,
        .Struct => |s| {
            inline for (s.fields) |field| {
                if (!shallow_eql(@field(a, field.name), @field(b, field.name))) return false;
            }
            return true;
        },
        else => unreachable,
    };
}

pub fn remove_union_voids(comptime t: type) type {
    switch (@typeInfo(t)) {
        .Union => |u| {
            var fields: [u.fields.len]std.builtin.Type.UnionField = .{};
            var n_fields: usize = 0;
            for (u.fields) |field| {
                if (field.type == void) continue;
                fields[n_fields] = field;
                n_fields += 1;
            }

            return @Type(std.builtin.Type{ .Union = .{
                .layout = u.layout,
                .tag_type = u.tag_type,
                .fields = fields[0..n_fields],
                .decls = u.decls,
            } });
        },
        else => @compileError("not a union"),
    }
}

pub fn fn_ptr_return_type(comptime F: type) type {
    const FI = @typeInfo(F);
    if (FI != .Pointer) @compileError("not a Pointer (expecting function pointer)");
    const FFI = @typeInfo(FI.Pointer.child);
    if (FFI != .Fn) @compileError("not a Fn");
    return FFI.Fn.return_type.?;
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
