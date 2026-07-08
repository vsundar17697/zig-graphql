const std = @import("std");
const lexer_mod = @import("lexer.zig");
const ast = @import("ast.zig");

const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const TokenType = lexer_mod.TokenType;

pub const Error = lexer_mod.Error || error{ UnexpectedToken, ExpectedValue, InlineFragmentsNotSupported };

/// Recursive-descent parser for the full GraphQL document grammar this engine
/// supports: one or more operations (named or the anonymous shorthand),
/// fragment definitions (spread anywhere a selection is expected, forward
/// references allowed), directives, and variable definitions/references.
/// Inline fragments (`... on Type { }`) are rejected -- see
/// `ast.FragmentSpread`'s doc comment for why they're never needed here.
///
/// The parser's output (`ast.Document`) is *raw*: fragment spreads are not
/// yet expanded, directives are not yet evaluated, and `$variable`
/// references are not yet substituted -- see `request.zig` for the
/// resolution pass that turns this into the flat `ast.Field` tree
/// `graphql_parser/to_ir.zig` consumes.
pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Error!Parser {
        var lex = Lexer.init(allocator, src);
        const first = try lex.next();
        return .{ .lexer = lex, .current = first, .allocator = allocator };
    }

    fn advance(self: *Parser) Error!void {
        self.current = try self.lexer.next();
    }

    fn expect(self: *Parser, token_type: TokenType) Error!Token {
        if (self.current.type != token_type) return Error.UnexpectedToken;
        const tok = self.current;
        try self.advance();
        return tok;
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) Error!void {
        const tok = try self.expect(.name);
        if (!std.mem.eql(u8, tok.text, keyword)) return Error.UnexpectedToken;
    }

    pub fn parseDocument(self: *Parser) Error!ast.Document {
        var operations: std.ArrayListUnmanaged(ast.Operation) = .empty;
        var fragments: std.ArrayListUnmanaged(ast.FragmentDefinition) = .empty;

        while (self.current.type != .eof) {
            if (self.current.type == .brace_l) {
                try operations.append(self.allocator, .{
                    .operation_type = .query,
                    .selection_set = try self.parseSelectionSet(),
                });
                continue;
            }

            const keyword = try self.expect(.name);
            if (std.mem.eql(u8, keyword.text, "fragment")) {
                try fragments.append(self.allocator, try self.parseFragmentDefinitionRest());
                continue;
            }

            var operation_type: ast.OperationType = .query;
            if (std.mem.eql(u8, keyword.text, "mutation")) {
                operation_type = .mutation;
            } else if (!std.mem.eql(u8, keyword.text, "query")) {
                return Error.UnexpectedToken;
            }

            var name: ?[]const u8 = null;
            if (self.current.type == .name) {
                name = self.current.text;
                try self.advance();
            }

            const variable_definitions = if (self.current.type == .paren_l)
                try self.parseVariableDefinitions()
            else
                &.{};

            _ = try self.parseDirectivesOpt(); // operation-level directives: parsed, not semantically used

            try operations.append(self.allocator, .{
                .operation_type = operation_type,
                .name = name,
                .variable_definitions = variable_definitions,
                .selection_set = try self.parseSelectionSet(),
            });
        }

        return .{
            .operations = try operations.toOwnedSlice(self.allocator),
            .fragments = try fragments.toOwnedSlice(self.allocator),
        };
    }

    fn parseFragmentDefinitionRest(self: *Parser) Error!ast.FragmentDefinition {
        const name = (try self.expect(.name)).text;
        try self.expectKeyword("on");
        const type_condition = (try self.expect(.name)).text;
        _ = try self.parseDirectivesOpt();
        return .{ .name = name, .type_condition = type_condition, .selection_set = try self.parseSelectionSet() };
    }

    fn parseVariableDefinitions(self: *Parser) Error![]const ast.VariableDefinition {
        _ = try self.expect(.paren_l);
        var defs: std.ArrayListUnmanaged(ast.VariableDefinition) = .empty;
        while (self.current.type != .paren_r) {
            _ = try self.expect(.dollar);
            const name = (try self.expect(.name)).text;
            _ = try self.expect(.colon);
            const type_name = try self.parseTypeText();

            var default_value: ?ast.Value = null;
            if (self.current.type == .equals) {
                try self.advance();
                default_value = try self.parseValue();
            }

            try defs.append(self.allocator, .{ .name = name, .type_name = type_name, .default_value = default_value });
        }
        _ = try self.expect(.paren_r);
        return defs.toOwnedSlice(self.allocator);
    }

    /// Reconstructs a canonical textual type reference (`Int`, `[String!]!`,
    /// ...) -- kept as text since nothing here type-checks a variable's
    /// declared type against its supplied value.
    fn parseTypeText(self: *Parser) Error![]const u8 {
        if (self.current.type == .bracket_l) {
            try self.advance();
            const inner = try self.parseTypeText();
            _ = try self.expect(.bracket_r);
            const suffix: []const u8 = if (self.current.type == .bang) blk: {
                try self.advance();
                break :blk "!";
            } else "";
            return std.fmt.allocPrint(self.allocator, "[{s}]{s}", .{ inner, suffix });
        }
        const name_tok = try self.expect(.name);
        const suffix: []const u8 = if (self.current.type == .bang) blk: {
            try self.advance();
            break :blk "!";
        } else "";
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ name_tok.text, suffix });
    }

    fn parseDirectivesOpt(self: *Parser) Error![]const ast.Directive {
        if (self.current.type != .at) return &.{};
        var directives: std.ArrayListUnmanaged(ast.Directive) = .empty;
        while (self.current.type == .at) {
            try self.advance();
            const name = (try self.expect(.name)).text;
            const arguments = if (self.current.type == .paren_l) try self.parseArguments() else &.{};
            try directives.append(self.allocator, .{ .name = name, .arguments = arguments });
        }
        return directives.toOwnedSlice(self.allocator);
    }

    fn parseSelectionSet(self: *Parser) Error![]const ast.Selection {
        _ = try self.expect(.brace_l);
        var selections: std.ArrayListUnmanaged(ast.Selection) = .empty;
        while (self.current.type != .brace_r) {
            try selections.append(self.allocator, try self.parseSelection());
        }
        _ = try self.expect(.brace_r);
        return selections.toOwnedSlice(self.allocator);
    }

    fn parseSelection(self: *Parser) Error!ast.Selection {
        if (self.current.type == .spread) {
            try self.advance();
            if (self.current.type == .name and std.mem.eql(u8, self.current.text, "on")) {
                return Error.InlineFragmentsNotSupported;
            }
            const name = (try self.expect(.name)).text;
            const directives = try self.parseDirectivesOpt();
            return .{ .fragment_spread = .{ .name = name, .directives = directives } };
        }
        return .{ .field = try self.parseRawField() };
    }

    fn parseRawField(self: *Parser) Error!ast.RawField {
        const first = try self.expect(.name);
        var alias: ?[]const u8 = null;
        var name = first.text;
        if (self.current.type == .colon) {
            try self.advance();
            alias = first.text;
            name = (try self.expect(.name)).text;
        }

        const arguments = if (self.current.type == .paren_l) try self.parseArguments() else &.{};
        const directives = try self.parseDirectivesOpt();
        const selection_set = if (self.current.type == .brace_l) try self.parseSelectionSet() else &.{};

        return .{ .alias = alias, .name = name, .arguments = arguments, .directives = directives, .selection_set = selection_set };
    }

    fn parseArguments(self: *Parser) Error![]const ast.Argument {
        _ = try self.expect(.paren_l);
        var args: std.ArrayListUnmanaged(ast.Argument) = .empty;
        while (self.current.type != .paren_r) {
            const name_tok = try self.expect(.name);
            _ = try self.expect(.colon);
            const value = try self.parseValue();
            try args.append(self.allocator, .{ .name = name_tok.text, .value = value });
        }
        _ = try self.expect(.paren_r);
        return args.toOwnedSlice(self.allocator);
    }

    fn parseValue(self: *Parser) Error!ast.Value {
        switch (self.current.type) {
            .dollar => {
                try self.advance();
                const name = (try self.expect(.name)).text;
                return .{ .variable = name };
            },
            .int => {
                const text = self.current.text;
                try self.advance();
                return .{ .int = std.fmt.parseInt(i64, text, 10) catch return Error.UnexpectedToken };
            },
            .float => {
                const text = self.current.text;
                try self.advance();
                return .{ .float = std.fmt.parseFloat(f64, text) catch return Error.UnexpectedToken };
            },
            .string => {
                const text = self.current.text;
                try self.advance();
                return .{ .string = text };
            },
            .name => {
                const text = self.current.text;
                try self.advance();
                if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, text, "null")) return .null_;
                return .{ .enum_ = text };
            },
            .bracket_l => return self.parseList(),
            .brace_l => return self.parseObject(),
            else => return Error.ExpectedValue,
        }
    }

    fn parseList(self: *Parser) Error!ast.Value {
        _ = try self.expect(.bracket_l);
        var items: std.ArrayListUnmanaged(ast.Value) = .empty;
        while (self.current.type != .bracket_r) {
            try items.append(self.allocator, try self.parseValue());
        }
        _ = try self.expect(.bracket_r);
        return .{ .list = try items.toOwnedSlice(self.allocator) };
    }

    fn parseObject(self: *Parser) Error!ast.Value {
        _ = try self.expect(.brace_l);
        var fields: std.ArrayListUnmanaged(ast.ObjectField) = .empty;
        while (self.current.type != .brace_r) {
            const name_tok = try self.expect(.name);
            _ = try self.expect(.colon);
            const value = try self.parseValue();
            try fields.append(self.allocator, .{ .name = name_tok.text, .value = value });
        }
        _ = try self.expect(.brace_r);
        return .{ .object = try fields.toOwnedSlice(self.allocator) };
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) Error!ast.Document {
    var parser = try Parser.init(allocator, src);
    return parser.parseDocument();
}

test "parses a scalar-only selection set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "{ album { AlbumId Title } }");

    try std.testing.expectEqual(@as(usize, 1), doc.operations.len);
    const op = doc.operations[0];
    try std.testing.expectEqual(ast.OperationType.query, op.operation_type);
    try std.testing.expectEqual(@as(usize, 1), op.selection_set.len);

    const root = op.selection_set[0].field;
    try std.testing.expectEqualStrings("album", root.name);
    try std.testing.expectEqual(@as(usize, 2), root.selection_set.len);
    try std.testing.expectEqualStrings("AlbumId", root.selection_set[0].field.name);
}

test "parses arguments with a nested relationship field and an alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\{ album(limit: 10) { title band: artist { name } } }
    );

    const root = doc.operations[0].selection_set[0].field;
    try std.testing.expectEqual(@as(usize, 1), root.arguments.len);
    try std.testing.expectEqualStrings("limit", root.arguments[0].name);
    try std.testing.expectEqual(@as(i64, 10), root.arguments[0].value.int);

    const artist_field = root.selection_set[1].field;
    try std.testing.expectEqualStrings("band", artist_field.alias.?);
    try std.testing.expectEqualStrings("artist", artist_field.name);
    try std.testing.expectEqualStrings("band", artist_field.responseKey());
}

test "parses a where argument with nested logical operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\{ album(where: {_and: [{AlbumId: {_gt: 1}}, {_not: {Title: {_is_null: true}}}]}) { title } }
    );

    const root = doc.operations[0].selection_set[0].field;
    const where = root.arguments[0].value;
    try std.testing.expectEqualStrings("where", root.arguments[0].name);

    const and_list = where.object[0];
    try std.testing.expectEqualStrings("_and", and_list.name);
    try std.testing.expectEqual(@as(usize, 2), and_list.value.list.len);

    const first_clause = and_list.value.list[0].object[0];
    try std.testing.expectEqualStrings("AlbumId", first_clause.name);
    try std.testing.expectEqualStrings("_gt", first_clause.value.object[0].name);
    try std.testing.expectEqual(@as(i64, 1), first_clause.value.object[0].value.int);
}

test "parses an order_by list of single-key objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\{ album(order_by: [{title: asc}]) { title } }
    );

    const root = doc.operations[0].selection_set[0].field;
    const order_by = root.arguments[0].value.list;
    try std.testing.expectEqual(@as(usize, 1), order_by.len);
    try std.testing.expectEqualStrings("title", order_by[0].object[0].name);
    try std.testing.expectEqualStrings("asc", order_by[0].object[0].value.enum_);
}

test "rejects a malformed document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.UnexpectedToken, parse(arena.allocator(), "{ album("));
}

test "parses a mutation document with a single root field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\mutation { insert_album(object: {title: "Highway to Hell", artist_id: 1}) { album_id title } }
    );

    try std.testing.expectEqual(@as(usize, 1), doc.operations.len);
    const op = doc.operations[0];
    try std.testing.expectEqual(ast.OperationType.mutation, op.operation_type);
    try std.testing.expectEqual(@as(usize, 1), op.selection_set.len);
    const root = op.selection_set[0].field;
    try std.testing.expectEqualStrings("insert_album", root.name);
    try std.testing.expectEqual(@as(usize, 1), root.arguments.len);
    try std.testing.expectEqualStrings("object", root.arguments[0].name);
    try std.testing.expectEqual(@as(usize, 2), root.selection_set.len);
}

test "parses a mutation document with multiple root fields, one per operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\mutation {
        \\  first: insert_album(object: {title: "A", artist_id: 1}) { album_id }
        \\  second: delete_album_by_pk(pk_columns: {album_id: 1}) { album_id }
        \\}
    );

    const op = doc.operations[0];
    try std.testing.expectEqual(ast.OperationType.mutation, op.operation_type);
    try std.testing.expectEqual(@as(usize, 2), op.selection_set.len);
    try std.testing.expectEqualStrings("insert_album", op.selection_set[0].field.name);
    try std.testing.expectEqualStrings("first", op.selection_set[0].field.alias.?);
    try std.testing.expectEqualStrings("delete_album_by_pk", op.selection_set[1].field.name);
}

test "a query document still parses with exactly one root field and operation defaults to query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "{ album { AlbumId } }");

    try std.testing.expectEqual(ast.OperationType.query, doc.operations[0].operation_type);
    try std.testing.expectEqual(@as(usize, 1), doc.operations[0].selection_set.len);
}

test "a query document now allows multiple root fields, like mutations already did" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "{ album { AlbumId } artist { Name } }");

    try std.testing.expectEqual(@as(usize, 2), doc.operations[0].selection_set.len);
    try std.testing.expectEqualStrings("album", doc.operations[0].selection_set[0].field.name);
    try std.testing.expectEqualStrings("artist", doc.operations[0].selection_set[1].field.name);
}

test "parses a named operation with variable definitions and a variable reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\query GetAlbums($artistId: Int!, $limit: Int = 10) { album(where: {artist_id: {_eq: $artistId}}, limit: $limit) { title } }
    );

    const op = doc.operations[0];
    try std.testing.expectEqualStrings("GetAlbums", op.name.?);
    try std.testing.expectEqual(@as(usize, 2), op.variable_definitions.len);
    try std.testing.expectEqualStrings("artistId", op.variable_definitions[0].name);
    try std.testing.expectEqualStrings("Int!", op.variable_definitions[0].type_name);
    try std.testing.expectEqualStrings("limit", op.variable_definitions[1].name);
    try std.testing.expectEqualStrings("Int", op.variable_definitions[1].type_name);
    try std.testing.expectEqual(@as(i64, 10), op.variable_definitions[1].default_value.?.int);

    const root = op.selection_set[0].field;
    const where = root.arguments[0].value.object[0].value.object[0];
    try std.testing.expectEqualStrings("artistId", where.value.variable);
    try std.testing.expectEqualStrings("limit", root.arguments[1].value.variable);
}

test "parses a nested list variable type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "query($ids: [Int!]!) { album { title } }");
    try std.testing.expectEqualStrings("[Int!]!", doc.operations[0].variable_definitions[0].type_name);
}

test "parses directives on a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "query($skipTitle: Boolean!) { album { title @skip(if: $skipTitle) AlbumId } }");

    const root = doc.operations[0].selection_set[0].field;
    const title_field = root.selection_set[0].field;
    try std.testing.expectEqual(@as(usize, 1), title_field.directives.len);
    try std.testing.expectEqualStrings("skip", title_field.directives[0].name);
    try std.testing.expectEqualStrings("if", title_field.directives[0].arguments[0].name);
}

test "parses a fragment spread and a fragment definition, in either order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\{ album { ...AlbumFields } }
        \\fragment AlbumFields on Album { title AlbumId }
    );

    try std.testing.expectEqual(@as(usize, 1), doc.operations.len);
    try std.testing.expectEqual(@as(usize, 1), doc.fragments.len);

    const root = doc.operations[0].selection_set[0].field;
    try std.testing.expectEqual(@as(usize, 1), root.selection_set.len);
    try std.testing.expectEqualStrings("AlbumFields", root.selection_set[0].fragment_spread.name);

    const fragment = doc.fragments[0];
    try std.testing.expectEqualStrings("AlbumFields", fragment.name);
    try std.testing.expectEqualStrings("Album", fragment.type_condition);
    try std.testing.expectEqual(@as(usize, 2), fragment.selection_set.len);
}

test "rejects an inline fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        Error.InlineFragmentsNotSupported,
        parse(arena.allocator(), "{ album { ... on Album { title } } }"),
    );
}
