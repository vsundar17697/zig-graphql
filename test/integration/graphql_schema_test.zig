const std = @import("std");
const pg_gql = @import("pg_gql");
const fixture = @import("fixture.zig");

// M4.4 checkpoint: a golden SDL snapshot against the real fixture schema.
// Asserted as a set of exact substrings rather than one full byte-exact
// document -- a full snapshot would be hundreds of lines and re-break on
// every unrelated schema change this session, while these substrings pin
// every non-obvious naming/nullability rule docs/decisions/0013 makes.
test "SDL rendered from the live fixture schema has the expected shapes" {
    const allocator = std.testing.allocator;

    const conn = try fixture.connect(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try pg_gql.executor.introspectLive(a, conn);
    const type_system = try pg_gql.graphql_schema.buildTypeSystem(a, &schema_model);
    const text = try pg_gql.graphql_schema.renderSdl(a, &type_system);

    try std.testing.expect(std.mem.indexOf(u8, text, "schema {\n  query: query_root\n  mutation: mutation_root\n}") != null);

    // album's forward relationship to artist is non-null (artist_id is NOT NULL).
    try std.testing.expect(std.mem.indexOf(u8, text, "type album {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  artist: artist!\n") != null);

    // artist's reverse relationship is always qualified by column, and non-null list of non-null.
    try std.testing.expect(std.mem.indexOf(u8, text, "  album_by_artist_id(where: album_bool_exp, order_by: [album_order_by!], limit: Int, offset: Int): [album!]!\n") != null);

    // Root query fields: plain collection field + its _aggregate sibling.
    try std.testing.expect(std.mem.indexOf(u8, text, "  album(where: album_bool_exp, order_by: [album_order_by!], limit: Int, offset: Int): [album!]!\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  album_aggregate(where: album_bool_exp, order_by: [album_order_by!], limit: Int, offset: Int): album_aggregate_fields!\n") != null);

    // Mutation root: insert/update_by_pk/delete_by_pk for both PK'd collections.
    try std.testing.expect(std.mem.indexOf(u8, text, "  insert_album(object: album_insert_input!): album\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  update_album_by_pk(pk_columns: album_pk_columns_input!, _set: album_set_input!): album\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  delete_album_by_pk(pk_columns: album_pk_columns_input!): album\n") != null);

    // album_id is a serial PK (has_default) -- optional in insert_input, required in pk_columns_input.
    try std.testing.expect(std.mem.indexOf(u8, text, "input album_insert_input {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  album_id: Int\n") != null); // optional: no "!"
    try std.testing.expect(std.mem.indexOf(u8, text, "input album_pk_columns_input {\n  album_id: Int!\n}") != null);

    // Aggregate types: flat root field returns aggregate_fields directly; max/min/etc. are nullable per-column objects.
    try std.testing.expect(std.mem.indexOf(u8, text, "type album_aggregate_fields {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  count(distinct: Boolean): Int!\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type album_max_fields {") != null);

    // Comparison-exp types are shared across every column of that scalar type.
    try std.testing.expect(std.mem.indexOf(u8, text, "input Int_comparison_exp {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "input String_comparison_exp {") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "enum order_by {\n  asc\n  desc\n}") != null);

    // Int/String/Boolean are GraphQL built-ins -- no `scalar` declaration.
    try std.testing.expect(std.mem.indexOf(u8, text, "scalar Int\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scalar String\n") == null);
}

// M4.5 checkpoint: the actual fragment-heavy introspection document real
// clients (GraphiQL, Apollo, urql) send, executed against the live fixture
// schema -- proves fragment expansion (request.zig) and introspection
// execution compose correctly end to end, not just against a hand-built
// fixture schema in the unit tests.
test "the canonical GraphiQL/Apollo introspection query executes against the live fixture schema" {
    const allocator = std.testing.allocator;

    const conn = try fixture.connect(allocator);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_model = try pg_gql.executor.introspectLive(a, conn);
    const type_system = try pg_gql.graphql_schema.buildTypeSystem(a, &schema_model);

    const document = try pg_gql.graphql_parser.parse(a,
        \\query IntrospectionQuery {
        \\  __schema {
        \\    queryType { name }
        \\    mutationType { name }
        \\    types { ...FullType }
        \\    directives { name locations args { ...InputValue } }
        \\  }
        \\}
        \\fragment FullType on __Type {
        \\  kind
        \\  name
        \\  fields(includeDeprecated: true) {
        \\    name
        \\    args { ...InputValue }
        \\    type { ...TypeRef }
        \\    isDeprecated
        \\    deprecationReason
        \\  }
        \\  inputFields { ...InputValue }
        \\  interfaces { ...TypeRef }
        \\  enumValues(includeDeprecated: true) { name isDeprecated deprecationReason }
        \\  possibleTypes { ...TypeRef }
        \\}
        \\fragment InputValue on __InputValue {
        \\  name
        \\  type { ...TypeRef }
        \\  defaultValue
        \\}
        \\fragment TypeRef on __Type {
        \\  kind
        \\  name
        \\  ofType {
        \\    kind
        \\    name
        \\    ofType {
        \\      kind
        \\      name
        \\      ofType {
        \\        kind
        \\        name
        \\        ofType {
        \\          kind
        \\          name
        \\          ofType {
        \\            kind
        \\            name
        \\            ofType {
        \\              kind
        \\              name
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    );
    const resolved = try pg_gql.graphql_parser.resolveOperation(a, &document, null, null);
    const result = try pg_gql.graphql_schema.executeIntrospection(a, &type_system, resolved.root_fields);

    const schema_obj = result.object.get("__schema").?.object;
    try std.testing.expectEqualStrings("query_root", schema_obj.get("queryType").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("mutation_root", schema_obj.get("mutationType").?.object.get("name").?.string);

    const types = schema_obj.get("types").?.array;
    var found_album = false;
    for (types.items) |t| {
        if (t.object.get("name").? == .string and std.mem.eql(u8, t.object.get("name").?.string, "album")) found_album = true;
    }
    try std.testing.expect(found_album);
}
