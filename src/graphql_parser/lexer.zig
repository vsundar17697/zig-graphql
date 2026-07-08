const std = @import("std");

pub const TokenType = enum {
    name,
    int,
    float,
    string,
    brace_l,
    brace_r,
    paren_l,
    paren_r,
    bracket_l,
    bracket_r,
    colon,
    bang,
    dollar,
    at,
    spread,
    equals,
    eof,
};

pub const Token = struct {
    type: TokenType,
    /// For `.string`, this is the already-unescaped value; for everything
    /// else it borrows directly from the source text (see Lexer doc comment).
    text: []const u8,
};

pub const Error = error{ UnexpectedCharacter, UnterminatedString, InvalidEscape, InvalidNumber } || std.mem.Allocator.Error;

/// Tokenizes a GraphQL document. Tokens borrow directly from `src` wherever
/// possible (names, numbers, punctuators) rather than copying -- callers must
/// keep `src` alive for as long as any AST/IR built from these tokens is used.
/// Only string values may allocate (via `allocator`), and only when they
/// contain an escape sequence; the common escape-free case still borrows.
pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .allocator = allocator };
    }

    fn skipIgnored(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r', ',' => self.pos += 1,
                '#' => while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                },
                else => return,
            }
        }
    }

    pub fn next(self: *Lexer) Error!Token {
        self.skipIgnored();
        if (self.pos >= self.src.len) return .{ .type = .eof, .text = "" };

        const c = self.src[self.pos];
        switch (c) {
            '{' => return self.single(.brace_l),
            '}' => return self.single(.brace_r),
            '(' => return self.single(.paren_l),
            ')' => return self.single(.paren_r),
            '[' => return self.single(.bracket_l),
            ']' => return self.single(.bracket_r),
            ':' => return self.single(.colon),
            '!' => return self.single(.bang),
            '$' => return self.single(.dollar),
            '@' => return self.single(.at),
            '=' => return self.single(.equals),
            '.' => return self.readSpread(),
            '"' => return self.readString(),
            '-', '0'...'9' => return self.readNumber(),
            'a'...'z', 'A'...'Z', '_' => return self.readName(),
            else => return Error.UnexpectedCharacter,
        }
    }

    /// GraphQL only ever uses `.` as part of the three-dot spread operator
    /// (`...`) -- a lone or double dot is a lexical error.
    fn readSpread(self: *Lexer) Error!Token {
        if (self.pos + 3 <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "...")) {
            const text = self.src[self.pos .. self.pos + 3];
            self.pos += 3;
            return .{ .type = .spread, .text = text };
        }
        return Error.UnexpectedCharacter;
    }

    fn single(self: *Lexer, token_type: TokenType) Token {
        const text = self.src[self.pos .. self.pos + 1];
        self.pos += 1;
        return .{ .type = token_type, .text = text };
    }

    fn readName(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
        }
        return .{ .type = .name, .text = self.src[start..self.pos] };
    }

    fn readNumber(self: *Lexer) Error!Token {
        const start = self.pos;
        if (self.src[self.pos] == '-') self.pos += 1;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;

        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }

        const text = self.src[start..self.pos];
        if (text.len == 0 or (text.len == 1 and text[0] == '-')) return Error.InvalidNumber;
        return .{ .type = if (is_float) .float else .int, .text = text };
    }

    fn readString(self: *Lexer) Error!Token {
        std.debug.assert(self.src[self.pos] == '"');
        const start = self.pos;
        self.pos += 1;

        var has_escape = false;
        while (true) {
            if (self.pos >= self.src.len) return Error.UnterminatedString;
            const c = self.src[self.pos];
            if (c == '"') break;
            if (c == '\\') {
                has_escape = true;
                self.pos += 2;
                continue;
            }
            self.pos += 1;
        }
        const raw = self.src[start + 1 .. self.pos];
        self.pos += 1; // closing quote

        if (!has_escape) return .{ .type = .string, .text = raw };

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const escaped: u8 = switch (raw[i + 1]) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return Error.InvalidEscape,
                };
                try out.append(self.allocator, escaped);
                i += 2;
            } else {
                try out.append(self.allocator, raw[i]);
                i += 1;
            }
        }
        return .{ .type = .string, .text = try out.toOwnedSlice(self.allocator) };
    }
};

test "lexes punctuators, names, numbers and a simple string" {
    var lexer = Lexer.init(std.testing.allocator, "{ album(limit: 10) }");
    const expected = [_]TokenType{ .brace_l, .name, .paren_l, .name, .colon, .int, .paren_r, .brace_r, .eof };
    for (expected) |expected_type| {
        const tok = try lexer.next();
        try std.testing.expectEqual(expected_type, tok.type);
    }
}

test "lexes negative and floating point numbers" {
    var lexer = Lexer.init(std.testing.allocator, "-42 3.14 -0.5");
    const a = try lexer.next();
    try std.testing.expectEqual(TokenType.int, a.type);
    try std.testing.expectEqualStrings("-42", a.text);

    const b = try lexer.next();
    try std.testing.expectEqual(TokenType.float, b.type);
    try std.testing.expectEqualStrings("3.14", b.text);

    const c = try lexer.next();
    try std.testing.expectEqual(TokenType.float, c.type);
    try std.testing.expectEqualStrings("-0.5", c.text);
}

test "lexes a string without escapes as a zero-copy slice into source" {
    const src = "\"AC/DC\"";
    var lexer = Lexer.init(std.testing.allocator, src);
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings("AC/DC", tok.text);
    // Confirm it's actually borrowed, not copied: same backing pointer.
    try std.testing.expectEqual(@intFromPtr(src.ptr) + 1, @intFromPtr(tok.text.ptr));
}

test "lexes a string with escapes into a freshly allocated buffer" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "\"line1\\nline2 say \\\"hi\\\"\"");
    const tok = try lexer.next();
    defer allocator.free(tok.text);
    try std.testing.expectEqualStrings("line1\nline2 say \"hi\"", tok.text);
}

test "skips comments" {
    var lexer = Lexer.init(std.testing.allocator, "# a comment\nalbum");
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.name, tok.type);
    try std.testing.expectEqualStrings("album", tok.text);
}

test "rejects an unterminated string" {
    var lexer = Lexer.init(std.testing.allocator, "\"unterminated");
    try std.testing.expectError(Error.UnterminatedString, lexer.next());
}

test "lexes dollar, at, and spread tokens" {
    var lexer = Lexer.init(std.testing.allocator, "$foo @skip ...Frag");
    const dollar = try lexer.next();
    try std.testing.expectEqual(TokenType.dollar, dollar.type);
    const name1 = try lexer.next();
    try std.testing.expectEqualStrings("foo", name1.text);
    const at = try lexer.next();
    try std.testing.expectEqual(TokenType.at, at.type);
    const name2 = try lexer.next();
    try std.testing.expectEqualStrings("skip", name2.text);
    const spread = try lexer.next();
    try std.testing.expectEqual(TokenType.spread, spread.type);
    try std.testing.expectEqualStrings("...", spread.text);
}

test "rejects a lone or double dot" {
    var lexer = Lexer.init(std.testing.allocator, "..");
    try std.testing.expectError(Error.UnexpectedCharacter, lexer.next());
}
