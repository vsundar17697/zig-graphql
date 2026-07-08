# pg-gql

[![CI](https://github.com/vsundar17697/zig-graphql/actions/workflows/ci.yml/badge.svg)](https://github.com/vsundar17697/zig-graphql/actions/workflows/ci.yml)

A Postgres-backed GraphQL engine written in Zig, structured Hasura-NDC-style: a
GraphQL-to-IR translation layer and an NDC-postgres-compatible connector core, both usable
as a library (pure Zig + C ABI) and as a standalone HTTP server.

Current status: milestone 1 complete -- single-collection queries plus one object
relationship, through three interchangeable producers (GraphQL text, a typed query
builder, and literal NDC QueryRequest JSON over HTTP), executing against real Postgres
via libpq (see [ADR 0016](docs/decisions/0016-adopt-libpq.md)). See [docs/roadmap.md](docs/roadmap.md)
for exact scope and what's deferred, and [docs/architecture.md](docs/architecture.md) for
the module design. Non-obvious decisions are recorded as ADRs under [docs/decisions/](docs/decisions/).

Run the server and try it yourself:

```sh
docker compose up -d --wait
zig build
./zig-out/bin/pg-gql-server &
curl http://127.0.0.1:8080/schema
curl -X POST http://127.0.0.1:8080/query -H 'Content-Type: application/json' -d '{
  "collection": "album",
  "query": {"fields": {"title": {"type": "column", "column": "title"}}, "limit": 5},
  "arguments": {}, "collection_relationships": {}
}'
```

## Requirements

- Zig 0.16.0+
- libpq (`brew install libpq` on macOS, `libpq-dev` on Debian/Ubuntu). Homebrew's keg-only
  install is found automatically; elsewhere, point the build at it with
  `zig build -Dlibpq-prefix=/path/to/libpq`.
- Docker (for Postgres-backed integration tests only — not needed for `zig build test`)

## Building and testing

```sh
zig build              # builds the library, the C ABI shared library, and pg-gql-server
zig build test         # fast unit tests, pure logic only, no Docker/network required
docker compose up -d --wait
zig build test-integration   # Postgres-backed integration tests
```

`zig build test-integration` connects to the Postgres started by `docker-compose.yml`
(`postgres://pggql:pggql@localhost:55432/pggql`).
