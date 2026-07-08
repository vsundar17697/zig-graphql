#ifndef PG_GQL_H
#define PG_GQL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * pg-gql C ABI.
 *
 * Every *_free_* function below must be called exactly once per successful
 * handle-returning call; each handle owns its own arena, so freeing it is
 * cheap regardless of how much was allocated while it was alive.
 *
 * Every handle-returning function returns NULL on failure. Call
 * pg_gql_last_error() to get a human-readable message for the most recent
 * failure on the calling thread.
 */

typedef struct PgGqlConnection PgGqlConnection;
typedef struct PgGqlSchema PgGqlSchema;
typedef struct PgGqlQueryResult PgGqlQueryResult;

const char *pg_gql_last_error(void);

PgGqlConnection *pg_gql_connect(
    const char *host,
    uint16_t port,
    const char *user,
    const char *password,
    const char *database
);
void pg_gql_close(PgGqlConnection *connection);

/* Introspects the live Postgres schema (see docs/roadmap.md for scope: a
 * single "public" schema, tables/views, foreign-key-derived relationships). */
PgGqlSchema *pg_gql_introspect_schema(PgGqlConnection *connection);
void pg_gql_free_schema(PgGqlSchema *schema);

/* Parses and runs a GraphQL query against `schema`, returning the result as
 * an NDC-shaped RowSet JSON document (`{"rows": [...]}`). */
PgGqlQueryResult *pg_gql_query_graphql(
    PgGqlConnection *connection,
    PgGqlSchema *schema,
    const char *query_text
);

/* Returned pointer is owned by `result` and valid until pg_gql_free_result
 * is called -- do not free it separately. */
const char *pg_gql_result_json(PgGqlQueryResult *result);
void pg_gql_free_result(PgGqlQueryResult *result);

#ifdef __cplusplus
}
#endif

#endif /* PG_GQL_H */
