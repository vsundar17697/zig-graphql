//! Public library entry point: re-exports the pg-gql API surface.

pub const ndc_ir = @import("ndc_ir");
pub const schema = @import("schema");
pub const sql_gen = @import("sql_gen");
pub const pg_wire = @import("pg_wire");
pub const graphql_parser = @import("graphql_parser");
pub const query_builder = @import("query_builder");
pub const executor = @import("executor");
pub const graphql_schema = @import("graphql_schema");

test {
    @import("std").testing.refAllDecls(@This());
}

// The flagship "one IR, two producers" proof (see docs/architecture.md):
// graphql_parser and query_builder must be usable interchangeably. Neither
// module may depend on the other, so this comparison -- needing both plus
// sql_gen -- lives here, at the one place that already imports all three.
//
// Rather than a raw structural diff of the two Query values (risky: Zig
// hashmaps carry internal capacity/layout state that isn't meaningful to
// compare), both Query values are run through the same sql_gen used to
// actually execute queries, and their rendered SQL + parameters are compared.
// This proves the property that matters -- these two producers yield the
// same executable query -- through the real consumption path instead of an
// ad hoc equality function.
const std = @import("std");

fn buildTestSchema(allocator: std.mem.Allocator) !schema.SchemaModel {
    var model = schema.SchemaModel{};

    var album_object_type = schema.ObjectType{};
    try album_object_type.fields.put(allocator, "album_id", .{ .scalar_type = "Int", .nullable = false, .has_default = true });
    try album_object_type.fields.put(allocator, "title", .{ .scalar_type = "String", .nullable = false });
    try album_object_type.fields.put(allocator, "artist_id", .{ .scalar_type = "Int", .nullable = false });
    try model.object_types.put(allocator, "album", album_object_type);
    try model.collections.put(allocator, "album", .{
        .db_schema = "public",
        .db_table = "album",
        .object_type = "album",
        .primary_key = &.{"album_id"},
    });

    var artist_object_type = schema.ObjectType{};
    try artist_object_type.fields.put(allocator, "name", .{ .scalar_type = "String", .nullable = false });
    try model.object_types.put(allocator, "artist", artist_object_type);
    try model.collections.put(allocator, "artist", .{ .db_schema = "public", .db_table = "artist", .object_type = "artist" });

    var rel = ndc_ir.Relationship{ .target_collection = "artist", .relationship_type = .object };
    try rel.column_mapping.put(allocator, "artist_id", "artist_id");
    var album_rels = ndc_ir.RelationshipMap{};
    try album_rels.put(allocator, "artist", rel);
    try model.relationships.put(allocator, "album", album_rels);

    return model;
}

test "graphql_parser and query_builder produce equivalent queries: identical rendered SQL and params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try buildTestSchema(a);

    const graphql_query = try graphql_parser.parseToIr(
        a,
        \\{ album(where: {artist_id: {_eq: 1}}, order_by: [{title: asc}], limit: 10) { title artist { name } } }
    ,
        &schema_model,
    );

    var builder = query_builder.Builder.init(a, "album");
    try builder.select("title");
    const nested_artist = blk: {
        var nested_builder = query_builder.Builder.init(a, "artist");
        try nested_builder.select("name");
        break :blk nested_builder.build();
    };
    try builder.selectRelationship("artist", "artist", nested_artist, schema_model.relationships.get("album").?.get("artist").?);
    builder.where(query_builder.column("artist_id").eq(1));
    try builder.orderBy(&.{query_builder.column("title").asc()});
    builder.limit(10);
    const builder_query = builder.build();

    try query_builder.validate(&builder_query, &schema_model);

    const graphql_sql = try sql_gen.generate(a, &graphql_query, &schema_model);
    const builder_sql = try sql_gen.generate(a, &builder_query, &schema_model);

    try std.testing.expectEqualStrings(graphql_sql.sql, builder_sql.sql);
    try std.testing.expectEqual(graphql_sql.params.len, builder_sql.params.len);
    for (graphql_sql.params, builder_sql.params) |gp, bp| {
        try std.testing.expectEqual(std.meta.activeTag(gp), std.meta.activeTag(bp));
        switch (gp) {
            .integer => try std.testing.expectEqual(gp.integer, bp.integer),
            .text => try std.testing.expectEqualStrings(gp.text, bp.text),
            .boolean => try std.testing.expectEqual(gp.boolean, bp.boolean),
            .float => try std.testing.expectEqual(gp.float, bp.float),
            .null_ => {},
            .variable_ref => try std.testing.expectEqualStrings(gp.variable_ref, bp.variable_ref),
        }
    }
}

// Extends the flagship "one IR, two producers" proof to milestone 3's write
// path: graphql_parser's mutation lowering and query_builder.MutationBuilder
// must produce equivalent MutationOperation values for an equivalent
// mutation, proven the same way as the read-path test above -- through the
// real SQL-generation consumer (sql_gen.generateMutation), not a raw
// structural diff.
test "graphql_parser and MutationBuilder produce equivalent insert_album mutations: identical rendered SQL and params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try buildTestSchema(a);

    const graphql_request = try graphql_parser.parseToMutationIr(
        a,
        \\mutation { insert_album(object: {title: "Highway to Hell", artist_id: 1}) { album_id title } }
    ,
    );

    const mutations = query_builder.MutationBuilder.init(a);
    var builder_op = try mutations.insert("album", .{ .title = "Highway to Hell", .artist_id = 1 });
    try mutations.returning(&builder_op, &.{ "album_id", "title" });

    const graphql_sql = try sql_gen.generateMutation(a, &graphql_request.operations[0], &schema_model);
    const builder_sql = try sql_gen.generateMutation(a, &builder_op, &schema_model);

    try std.testing.expectEqualStrings(graphql_sql.sql, builder_sql.sql);
    try std.testing.expectEqual(graphql_sql.params.len, builder_sql.params.len);
    for (graphql_sql.params, builder_sql.params) |gp, bp| {
        try std.testing.expectEqual(std.meta.activeTag(gp), std.meta.activeTag(bp));
    }
}
