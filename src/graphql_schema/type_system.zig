const std = @import("std");
const schema = @import("schema");

pub const Error = std.mem.Allocator.Error || schema.ProcedureError;

/// A type reference as it appears in a field's type, an argument's type, or
/// an input field's type -- may be wrapped in NON_NULL and/or LIST any
/// number of times around a named type. This is exactly the shape GraphQL's
/// own `__Type.ofType` introspection needs to walk (see
/// docs/decisions/0013-graphql-type-system.md).
pub const TypeRef = union(enum) {
    named: []const u8,
    list: *const TypeRef,
    non_null: *const TypeRef,
};

pub const FieldArgument = struct {
    name: []const u8,
    type: TypeRef,
};

pub const ObjectField = struct {
    name: []const u8,
    type: TypeRef,
    arguments: []const FieldArgument = &.{},
};

pub const ObjectTypeDef = struct {
    name: []const u8,
    fields: []const ObjectField,
};

pub const InputField = struct {
    name: []const u8,
    type: TypeRef,
};

pub const InputObjectTypeDef = struct {
    name: []const u8,
    fields: []const InputField,
};

pub const EnumTypeDef = struct {
    name: []const u8,
    values: []const []const u8,
};

pub const TypeDef = union(enum) {
    scalar: []const u8,
    object: ObjectTypeDef,
    input_object: InputObjectTypeDef,
    enum_: EnumTypeDef,
};

/// Every named type in the schema, keyed by name -- scalars, object types,
/// input object types, enums. `TypeRef.named` values are looked up here.
/// Built once at startup from `SchemaModel` + the procedure registry and
/// shared read-only across every request (see
/// docs/decisions/0013-graphql-type-system.md) -- SDL rendering and
/// introspection execution are two independent pure consumers of this one
/// structure.
pub const TypeSystem = struct {
    types: std.StringArrayHashMapUnmanaged(TypeDef) = .{},
    query_type_name: []const u8 = "query_root",
    mutation_type_name: ?[]const u8 = null,

    pub fn get(self: *const TypeSystem, name: []const u8) ?TypeDef {
        return self.types.get(name);
    }
};

fn named(name: []const u8) TypeRef {
    return .{ .named = name };
}

fn nonNull(allocator: std.mem.Allocator, inner: TypeRef) Error!TypeRef {
    const boxed = try allocator.create(TypeRef);
    boxed.* = inner;
    return .{ .non_null = boxed };
}

fn listOf(allocator: std.mem.Allocator, inner: TypeRef) Error!TypeRef {
    const boxed = try allocator.create(TypeRef);
    boxed.* = inner;
    return .{ .list = boxed };
}

/// GraphQL requires names to match `/[_A-Za-z][_0-9A-Za-z]*/`. A Postgres
/// identifier that doesn't (e.g. one containing a space or starting with a
/// digit) is excluded from the GraphQL surface only -- it keeps working on
/// the NDC surface unchanged. See docs/decisions/0013.
fn isGraphQLSafeName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn sortedKeys(allocator: std.mem.Allocator, comptime MapType: type, map: MapType) Error![]const []const u8 {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = map.keyIterator();
    while (it.next()) |k| try keys.append(allocator, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return keys.toOwnedSlice(allocator);
}

fn concatName(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

/// Registers `<Scalar>_comparison_exp` for `scalar_name` if not already
/// present -- shared across every column of that scalar type, across every
/// collection, so it's only built once no matter how many columns use it.
fn ensureComparisonExpType(allocator: std.mem.Allocator, ts: *TypeSystem, scalar_name: []const u8) Error!void {
    const type_name = try concatName(allocator, "{s}_comparison_exp", .{scalar_name});
    if (ts.types.contains(type_name)) return;

    const scalar_ref = named(scalar_name);
    const list_ref = try listOf(allocator, try nonNull(allocator, scalar_ref));
    const fields = try allocator.alloc(InputField, 7);
    fields[0] = .{ .name = "_eq", .type = scalar_ref };
    fields[1] = .{ .name = "_neq", .type = scalar_ref };
    fields[2] = .{ .name = "_gt", .type = scalar_ref };
    fields[3] = .{ .name = "_gte", .type = scalar_ref };
    fields[4] = .{ .name = "_lt", .type = scalar_ref };
    fields[5] = .{ .name = "_lte", .type = scalar_ref };
    fields[6] = .{ .name = "_in", .type = list_ref };
    // `_is_null` deliberately omitted from the generic comparison-exp type --
    // it's rendered as its own top-level bool_exp field instead (see
    // buildBoolExp), matching how `to_ir.zig`'s lowering already treats it as
    // a unary operator, not a binary comparison against a value.
    try ts.types.put(allocator, type_name, .{ .input_object = .{ .name = type_name, .fields = fields } });
}

fn buildBoolExp(allocator: std.mem.Allocator, ts: *TypeSystem, collection_name: []const u8, object_type: schema.ObjectType) Error!void {
    const type_name = try concatName(allocator, "{s}_bool_exp", .{collection_name});
    var fields: std.ArrayListUnmanaged(InputField) = .empty;

    var col_it = object_type.fields.iterator();
    while (col_it.next()) |entry| {
        if (!isGraphQLSafeName(entry.key_ptr.*)) continue;
        try ensureComparisonExpType(allocator, ts, entry.value_ptr.scalar_type);
        const comparison_type_name = try concatName(allocator, "{s}_comparison_exp", .{entry.value_ptr.scalar_type});
        try fields.append(allocator, .{ .name = entry.key_ptr.*, .type = named(comparison_type_name) });
    }

    const self_ref = named(type_name);
    const self_list = try listOf(allocator, try nonNull(allocator, self_ref));
    try fields.append(allocator, .{ .name = "_and", .type = self_list });
    try fields.append(allocator, .{ .name = "_or", .type = self_list });
    try fields.append(allocator, .{ .name = "_not", .type = self_ref });

    try ts.types.put(allocator, type_name, .{ .input_object = .{ .name = type_name, .fields = try fields.toOwnedSlice(allocator) } });
}

fn buildOrderBy(allocator: std.mem.Allocator, ts: *TypeSystem, collection_name: []const u8, object_type: schema.ObjectType) Error!void {
    const type_name = try concatName(allocator, "{s}_order_by", .{collection_name});
    var fields: std.ArrayListUnmanaged(InputField) = .empty;

    var col_it = object_type.fields.iterator();
    while (col_it.next()) |entry| {
        if (!isGraphQLSafeName(entry.key_ptr.*)) continue;
        try fields.append(allocator, .{ .name = entry.key_ptr.*, .type = named("order_by") });
    }

    try ts.types.put(allocator, type_name, .{ .input_object = .{ .name = type_name, .fields = try fields.toOwnedSlice(allocator) } });
}

/// `<t>_insert_input` (optional iff nullable or has_default, is_generated
/// columns excluded entirely) and `<t>_set_input` (all optional, is_generated
/// excluded) -- see docs/decisions/0010-mutation-procedure-naming.md's
/// insertability policy, which this mirrors in SDL form.
fn buildMutationInputs(allocator: std.mem.Allocator, ts: *TypeSystem, collection_name: []const u8, object_type: schema.ObjectType) Error!void {
    var insert_fields: std.ArrayListUnmanaged(InputField) = .empty;
    var set_fields: std.ArrayListUnmanaged(InputField) = .empty;

    var col_it = object_type.fields.iterator();
    while (col_it.next()) |entry| {
        if (!isGraphQLSafeName(entry.key_ptr.*)) continue;
        const field = entry.value_ptr.*;
        if (field.is_generated) continue;

        const scalar_ref = named(field.scalar_type);
        const insert_optional = field.nullable or field.has_default;
        const insert_type = if (insert_optional) scalar_ref else try nonNull(allocator, scalar_ref);
        try insert_fields.append(allocator, .{ .name = entry.key_ptr.*, .type = insert_type });
        try set_fields.append(allocator, .{ .name = entry.key_ptr.*, .type = scalar_ref });
    }

    const insert_name = try concatName(allocator, "{s}_insert_input", .{collection_name});
    try ts.types.put(allocator, insert_name, .{ .input_object = .{ .name = insert_name, .fields = try insert_fields.toOwnedSlice(allocator) } });

    const set_name = try concatName(allocator, "{s}_set_input", .{collection_name});
    try ts.types.put(allocator, set_name, .{ .input_object = .{ .name = set_name, .fields = try set_fields.toOwnedSlice(allocator) } });
}

/// `<t>_pk_columns_input` -- every declared primary-key column, always
/// required (see docs/decisions/0010: `pk_columns` must supply every PK
/// column, no more and no fewer). Only built for collections that have one.
fn buildPkColumnsInput(allocator: std.mem.Allocator, ts: *TypeSystem, collection_name: []const u8, collection: schema.Collection, object_type: schema.ObjectType) Error!void {
    if (collection.primary_key.len == 0) return;

    const fields = try allocator.alloc(InputField, collection.primary_key.len);
    for (collection.primary_key, fields) |pk_col, *dst| {
        const scalar_name = if (object_type.fields.get(pk_col)) |f| f.scalar_type else "String";
        dst.* = .{ .name = pk_col, .type = try nonNull(allocator, named(scalar_name)) };
    }

    const type_name = try concatName(allocator, "{s}_pk_columns_input", .{collection_name});
    try ts.types.put(allocator, type_name, .{ .input_object = .{ .name = type_name, .fields = fields } });
}

const aggregate_functions = [_][]const u8{ "max", "min", "sum", "avg" };

/// `<t>_aggregate_fields` (the `<t>_aggregate` query root field's direct
/// return type, per Gate 2's flat surface -- see
/// docs/decisions/0013-graphql-type-system.md) plus one `<t>_<fn>_fields`
/// object type per function, with one nullable field per column typed as
/// that column's own scalar type (an aggregate of zero rows is null, hence
/// nullable even for a NOT NULL source column). This is what makes the
/// restructured aggregate surface SDL-typeable at all: `max`'s return type
/// no longer depends on which column a caller asks for.
fn buildAggregateTypes(allocator: std.mem.Allocator, ts: *TypeSystem, collection_name: []const u8, object_type: schema.ObjectType) Error!void {
    var per_column_fields: std.ArrayListUnmanaged(ObjectField) = .empty;
    var col_it = object_type.fields.iterator();
    while (col_it.next()) |entry| {
        if (!isGraphQLSafeName(entry.key_ptr.*)) continue;
        try per_column_fields.append(allocator, .{ .name = entry.key_ptr.*, .type = named(entry.value_ptr.scalar_type) });
    }
    const owned_fields = try per_column_fields.toOwnedSlice(allocator);

    var aggregate_fields: std.ArrayListUnmanaged(ObjectField) = .empty;
    const count_int = try nonNull(allocator, named("Int"));
    const count_arguments = try allocator.alloc(FieldArgument, 1);
    count_arguments[0] = .{ .name = "distinct", .type = named("Boolean") };
    try aggregate_fields.append(allocator, .{
        .name = "count",
        .type = count_int,
        .arguments = count_arguments,
    });

    for (aggregate_functions) |function_name| {
        const fn_type_name = try concatName(allocator, "{s}_{s}_fields", .{ collection_name, function_name });
        try ts.types.put(allocator, fn_type_name, .{ .object = .{ .name = fn_type_name, .fields = owned_fields } });
        try aggregate_fields.append(allocator, .{ .name = function_name, .type = named(fn_type_name) });
    }

    const aggregate_fields_type_name = try concatName(allocator, "{s}_aggregate_fields", .{collection_name});
    try ts.types.put(allocator, aggregate_fields_type_name, .{ .object = .{ .name = aggregate_fields_type_name, .fields = try aggregate_fields.toOwnedSlice(allocator) } });
}

/// `where`/`order_by`/`limit`/`offset` -- every collection query field
/// (object relationship excluded: it takes no arguments; array relationships
/// and root collection fields both take this same set) shares this argument
/// list.
fn collectionArguments(allocator: std.mem.Allocator, collection_name: []const u8) Error![]const FieldArgument {
    const args = try allocator.alloc(FieldArgument, 4);
    args[0] = .{ .name = "where", .type = named(try concatName(allocator, "{s}_bool_exp", .{collection_name})) };
    args[1] = .{ .name = "order_by", .type = try listOf(allocator, try nonNull(allocator, named(try concatName(allocator, "{s}_order_by", .{collection_name})))) };
    args[2] = .{ .name = "limit", .type = named("Int") };
    args[3] = .{ .name = "offset", .type = named("Int") };
    return args;
}

fn buildObjectType(allocator: std.mem.Allocator, ts: *TypeSystem, schema_model: *const schema.SchemaModel, collection_name: []const u8, object_type: schema.ObjectType) Error!void {
    var fields: std.ArrayListUnmanaged(ObjectField) = .empty;

    var col_it = object_type.fields.iterator();
    while (col_it.next()) |entry| {
        if (!isGraphQLSafeName(entry.key_ptr.*)) continue;
        const scalar_ref = named(entry.value_ptr.scalar_type);
        const field_type = if (entry.value_ptr.nullable) scalar_ref else try nonNull(allocator, scalar_ref);
        try fields.append(allocator, .{ .name = entry.key_ptr.*, .type = field_type });
    }

    if (schema_model.relationships.get(collection_name)) |rel_map| {
        const rel_names = try sortedKeys(allocator, @TypeOf(rel_map), rel_map);
        for (rel_names) |rel_name| {
            if (!isGraphQLSafeName(rel_name)) continue;
            const rel = rel_map.get(rel_name).?;
            const target_ref = named(rel.target_collection);

            switch (rel.relationship_type) {
                .array => {
                    try fields.append(allocator, .{
                        .name = rel_name,
                        .type = try nonNull(allocator, try listOf(allocator, try nonNull(allocator, target_ref))),
                        .arguments = try collectionArguments(allocator, rel.target_collection),
                    });
                },
                .object => {
                    // Nullable unless every source (child-side) column in the
                    // mapping is itself NOT NULL -- a nullable FK column means
                    // the relationship can legitimately resolve to nothing.
                    var all_non_null = true;
                    var map_it = rel.column_mapping.iterator();
                    while (map_it.next()) |entry| {
                        const col = object_type.fields.get(entry.key_ptr.*) orelse {
                            all_non_null = false;
                            break;
                        };
                        if (col.nullable) {
                            all_non_null = false;
                            break;
                        }
                    }
                    const field_type = if (all_non_null) try nonNull(allocator, target_ref) else target_ref;
                    try fields.append(allocator, .{ .name = rel_name, .type = field_type });
                },
            }
        }
    }

    try ts.types.put(allocator, collection_name, .{ .object = .{ .name = collection_name, .fields = try fields.toOwnedSlice(allocator) } });
}

fn buildProcedureField(allocator: std.mem.Allocator, procedure_name: []const u8, procedure: schema.Procedure) Error!ObjectField {
    const return_type = named(procedure.collection); // nullable: a *_by_pk mutation on a missing row returns null (see docs/decisions/0011)
    return switch (procedure.kind) {
        .insert => blk: {
            const args = try allocator.alloc(FieldArgument, 1);
            args[0] = .{ .name = "object", .type = try nonNull(allocator, named(try concatName(allocator, "{s}_insert_input", .{procedure.collection}))) };
            break :blk .{ .name = procedure_name, .type = return_type, .arguments = args };
        },
        .update_by_pk => blk: {
            const args = try allocator.alloc(FieldArgument, 2);
            args[0] = .{ .name = "pk_columns", .type = try nonNull(allocator, named(try concatName(allocator, "{s}_pk_columns_input", .{procedure.collection}))) };
            args[1] = .{ .name = "_set", .type = try nonNull(allocator, named(try concatName(allocator, "{s}_set_input", .{procedure.collection}))) };
            break :blk .{ .name = procedure_name, .type = return_type, .arguments = args };
        },
        .delete_by_pk => blk: {
            const args = try allocator.alloc(FieldArgument, 1);
            args[0] = .{ .name = "pk_columns", .type = try nonNull(allocator, named(try concatName(allocator, "{s}_pk_columns_input", .{procedure.collection}))) };
            break :blk .{ .name = procedure_name, .type = return_type, .arguments = args };
        },
    };
}

/// Builds the full derived GraphQL type system from `schema_model` +
/// the auto-derived procedure registry, once, for the whole server's
/// lifetime -- see the `TypeSystem` doc comment.
pub fn build(allocator: std.mem.Allocator, schema_model: *const schema.SchemaModel) Error!TypeSystem {
    var ts = TypeSystem{};

    var scalar_it = schema_model.scalar_types.keyIterator();
    while (scalar_it.next()) |name| {
        try ts.types.put(allocator, name.*, .{ .scalar = name.* });
    }
    try ts.types.put(allocator, "order_by", .{ .enum_ = .{ .name = "order_by", .values = &.{ "asc", "desc" } } });

    const collection_names = try sortedKeys(allocator, @TypeOf(schema_model.collections), schema_model.collections);

    for (collection_names) |collection_name| {
        const collection = schema_model.collections.get(collection_name).?;
        const object_type = schema_model.object_types.get(collection.object_type) orelse schema.ObjectType{};

        try buildObjectType(allocator, &ts, schema_model, collection_name, object_type);
        try buildBoolExp(allocator, &ts, collection_name, object_type);
        try buildOrderBy(allocator, &ts, collection_name, object_type);
        try buildMutationInputs(allocator, &ts, collection_name, object_type);
        try buildPkColumnsInput(allocator, &ts, collection_name, collection, object_type);
        try buildAggregateTypes(allocator, &ts, collection_name, object_type);
    }

    var query_fields: std.ArrayListUnmanaged(ObjectField) = .empty;
    for (collection_names) |collection_name| {
        try query_fields.append(allocator, .{
            .name = collection_name,
            .type = try nonNull(allocator, try listOf(allocator, try nonNull(allocator, named(collection_name)))),
            .arguments = try collectionArguments(allocator, collection_name),
        });
        try query_fields.append(allocator, .{
            .name = try concatName(allocator, "{s}_aggregate", .{collection_name}),
            .type = try nonNull(allocator, named(try concatName(allocator, "{s}_aggregate_fields", .{collection_name}))),
            .arguments = try collectionArguments(allocator, collection_name),
        });
    }
    try ts.types.put(allocator, ts.query_type_name, .{ .object = .{ .name = ts.query_type_name, .fields = try query_fields.toOwnedSlice(allocator) } });

    const procedure_names = try schema.listProcedureNames(allocator, schema_model);
    if (procedure_names.len > 0) {
        var mutation_fields: std.ArrayListUnmanaged(ObjectField) = .empty;
        for (procedure_names) |procedure_name| {
            const procedure = try schema.resolveProcedure(schema_model, procedure_name);
            try mutation_fields.append(allocator, try buildProcedureField(allocator, procedure_name, procedure));
        }
        ts.mutation_type_name = "mutation_root";
        try ts.types.put(allocator, "mutation_root", .{ .object = .{ .name = "mutation_root", .fields = try mutation_fields.toOwnedSlice(allocator) } });
    }

    return ts;
}

fn testSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    var model = try schema.buildSchemaModel(allocator, .{
        .tables = &.{
            .{ .schema_name = "public", .table_name = "artist" },
            .{ .schema_name = "public", .table_name = "album" },
        },
        .columns = &.{
            .{ .table_name = "artist", .column_name = "artist_id", .pg_type = "integer", .nullable = false, .has_default = true },
            .{ .table_name = "artist", .column_name = "name", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "album_id", .pg_type = "integer", .nullable = false, .has_default = true },
            .{ .table_name = "album", .column_name = "title", .pg_type = "text", .nullable = false },
            .{ .table_name = "album", .column_name = "artist_id", .pg_type = "integer", .nullable = false },
        },
        .primary_keys = &.{
            .{ .table_name = "artist", .column_name = "artist_id" },
            .{ .table_name = "album", .column_name = "album_id" },
        },
        .foreign_keys = &.{
            .{ .constraint_name = "album_artist_id_fkey", .table_name = "album", .column_name = "artist_id", .foreign_table_name = "artist", .foreign_column_name = "artist_id" },
        },
    });
    _ = &model;
    return model;
}

test "build derives an object type with column and relationship fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try build(allocator, &schema_model);

    const album = ts.get("album").?.object;
    var found_title = false;
    for (album.fields) |f| {
        if (std.mem.eql(u8, f.name, "title")) found_title = true;
    }
    try std.testing.expect(found_title);

    var found_artist = false;
    for (album.fields) |f| {
        if (std.mem.eql(u8, f.name, "artist")) {
            found_artist = true;
            try std.testing.expect(f.type == .non_null); // artist_id is NOT NULL -> non-null object relationship
        }
    }
    try std.testing.expect(found_artist);

    const artist = ts.get("artist").?.object;
    var found_reverse = false;
    for (artist.fields) |f| {
        if (std.mem.eql(u8, f.name, "album_by_artist_id")) {
            found_reverse = true;
            try std.testing.expect(f.type == .non_null);
            try std.testing.expect(f.type.non_null.* == .list);
        }
    }
    try std.testing.expect(found_reverse);
}

test "build derives bool_exp, order_by, and mutation input types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try build(allocator, &schema_model);

    try std.testing.expect(ts.get("album_bool_exp") != null);
    try std.testing.expect(ts.get("album_order_by") != null);
    try std.testing.expect(ts.get("Int_comparison_exp") != null);
    try std.testing.expect(ts.get("String_comparison_exp") != null);

    const insert_input = ts.get("album_insert_input").?.input_object;
    var album_id_optional = false;
    for (insert_input.fields) |f| {
        if (std.mem.eql(u8, f.name, "album_id")) album_id_optional = (f.type == .named); // has_default -> optional (not non_null)
    }
    try std.testing.expect(album_id_optional);

    try std.testing.expect(ts.get("album_pk_columns_input") != null);
}

test "build derives aggregate field types with one nullable field per column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try build(allocator, &schema_model);

    const aggregate_fields = ts.get("album_aggregate_fields").?.object;
    var has_count = false;
    var has_max = false;
    for (aggregate_fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "count")) has_count = true;
        if (std.mem.eql(u8, f.name, "max")) has_max = true;
    }
    try std.testing.expect(has_count);
    try std.testing.expect(has_max);

    const max_fields = ts.get("album_max_fields").?.object;
    var has_title = false;
    for (max_fields.fields) |f| {
        if (std.mem.eql(u8, f.name, "title")) {
            has_title = true;
            try std.testing.expect(f.type == .named); // nullable even though title is NOT NULL on the base table
        }
    }
    try std.testing.expect(has_title);
}

test "build derives query_root and mutation_root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema_model = try testSchema(allocator);
    const ts = try build(allocator, &schema_model);

    const query_root = ts.get(ts.query_type_name).?.object;
    var has_album_field = false;
    var has_album_aggregate = false;
    for (query_root.fields) |f| {
        if (std.mem.eql(u8, f.name, "album")) has_album_field = true;
        if (std.mem.eql(u8, f.name, "album_aggregate")) has_album_aggregate = true;
    }
    try std.testing.expect(has_album_field);
    try std.testing.expect(has_album_aggregate);

    try std.testing.expect(ts.mutation_type_name != null);
    const mutation_root = ts.get(ts.mutation_type_name.?).?.object;
    var has_insert_album = false;
    for (mutation_root.fields) |f| {
        if (std.mem.eql(u8, f.name, "insert_album")) has_insert_album = true;
    }
    try std.testing.expect(has_insert_album);
}
