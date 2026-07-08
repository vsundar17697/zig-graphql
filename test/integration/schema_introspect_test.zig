const std = @import("std");
const pg_gql = @import("pg_gql");

fn connectToFixture(allocator: std.mem.Allocator) !*pg_gql.pg_wire.Connection {
    return pg_gql.pg_wire.Connection.connect(allocator, .{
        .host = "127.0.0.1",
        .port = 55432,
        .user = "pggql",
        .database = "pggql",
    }) catch |err| {
        std.debug.print(
            "\nfailed to connect to the test fixture Postgres at 127.0.0.1:55432 -- is `docker compose up -d --wait` running? ({t})\n",
            .{err},
        );
        return err;
    };
}

test "introspection discovers the seeded schema and both directions of the album <-> artist relationship" {
    const allocator = std.testing.allocator;
    const conn = try connectToFixture(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(arena.allocator(), conn);

    try std.testing.expect(schema_model.collections.contains("album"));
    try std.testing.expect(schema_model.collections.contains("artist"));

    const album_object_type = schema_model.object_types.get("album").?;
    try std.testing.expect(album_object_type.fields.contains("title"));
    try std.testing.expect(album_object_type.fields.contains("artist_id"));

    const album_collection = schema_model.collections.get("album").?;
    try std.testing.expectEqualStrings("album_id", album_collection.primary_key[0]);

    const album_relationships = schema_model.relationships.get("album").?;
    const rel = album_relationships.get("artist").?;
    try std.testing.expectEqualStrings("artist", rel.target_collection);
    try std.testing.expectEqual(pg_gql.ndc_ir.RelationshipType.object, rel.relationship_type);
    try std.testing.expectEqualStrings("artist_id", rel.column_mapping.get("artist_id").?);

    // `artist` has no outgoing FK, but does get the reverse (array) relationship
    // derived from album's FK, always qualified by column (see
    // docs/decisions/0012-permanent-relationship-naming.md).
    const artist_relationships = schema_model.relationships.get("artist").?;
    const reverse_rel = artist_relationships.get("album_by_artist_id").?;
    try std.testing.expectEqualStrings("album", reverse_rel.target_collection);
    try std.testing.expectEqual(pg_gql.ndc_ir.RelationshipType.array, reverse_rel.relationship_type);
    try std.testing.expectEqualStrings("artist_id", reverse_rel.column_mapping.get("artist_id").?);
}

// M4.0 checkpoint: has_default/is_generated must be populated from a LIVE
// database, not just fixture rows (see docs/decisions/0010's insertability
// policy and the M4 plan's pre-work item -- the live columns_query previously
// never selected column_default/is_identity/is_generated at all, so these
// silently defaulted to false against real Postgres despite being correctly
// threaded through by schema.buildSchemaModel).
test "live introspection populates has_default for a serial primary key and false for a plain NOT NULL column" {
    const allocator = std.testing.allocator;
    const conn = try connectToFixture(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schema_model = try pg_gql.executor.introspectLive(arena.allocator(), conn);

    const album_object_type = schema_model.object_types.get("album").?;
    try std.testing.expect(album_object_type.fields.get("album_id").?.has_default);
    try std.testing.expect(!album_object_type.fields.get("title").?.has_default);
    try std.testing.expect(!album_object_type.fields.get("album_id").?.is_generated);
}
