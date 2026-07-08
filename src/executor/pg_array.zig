//! Encodes element lists as Postgres array literals (the text format the
//! server parses for an array-typed parameter, e.g. `{"a","b",NULL}`), so a
//! whole array binds as one `$N` parameter -- see `= ANY($N)` in
//! sql_gen/render.zig and docs/decisions/0009-query-variables.md.
//!
//! Every non-null element is double-quoted unconditionally: quoting is always
//! legal, and it sidesteps the entire bare-element minefield (delimiters,
//! braces, whitespace trimming, and the string `NULL` reading as SQL NULL).
//! Inside quotes exactly two bytes need escaping, `"` and `\`.

const std = @import("std");

pub fn encodeLiteral(allocator: std.mem.Allocator, elements: []const ?[]const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    for (elements, 0..) |element, i| {
        if (i > 0) try out.append(allocator, ',');
        const text = element orelse {
            try out.appendSlice(allocator, "NULL");
            continue;
        };
        try out.append(allocator, '"');
        for (text) |byte| {
            if (byte == '"' or byte == '\\') try out.append(allocator, '\\');
            try out.append(allocator, byte);
        }
        try out.append(allocator, '"');
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn expectEncodes(expected: []const u8, elements: []const ?[]const u8) !void {
    const actual = try encodeLiteral(std.testing.allocator, elements);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "empty array" {
    try expectEncodes("{}", &.{});
}

test "plain elements are quoted" {
    try expectEncodes(
        \\{"a","b","c"}
    , &.{ "a", "b", "c" });
}

test "SQL NULL is bare; the string NULL stays quoted and distinct" {
    try expectEncodes(
        \\{NULL,"NULL"}
    , &.{ null, "NULL" });
}

test "empty string is a quoted nothing, not NULL" {
    try expectEncodes(
        \\{""}
    , &.{""});
}

test "delimiters and braces are neutralized by quoting alone" {
    try expectEncodes(
        \\{"a,b","{c}","  padded  "}
    , &.{ "a,b", "{c}", "  padded  " });
}

test "double quotes and backslashes are backslash-escaped" {
    try expectEncodes(
        \\{"say \"hi\"","C:\\path\\","\\\""}
    , &.{ "say \"hi\"", "C:\\path\\", "\\\"" });
}

test "multi-byte UTF-8 passes through unmodified" {
    try expectEncodes(
        \\{"héllo","日本語"}
    , &.{ "héllo", "日本語" });
}

test "newlines and control bytes pass through inside quotes" {
    try expectEncodes("{\"a\nb\",\"c\td\"}", &.{ "a\nb", "c\td" });
}
