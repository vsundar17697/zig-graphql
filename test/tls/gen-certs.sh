#!/usr/bin/env bash
# Generates a throwaway CA plus a server certificate for the TLS integration
# fixture (roadmap-v1.md milestone 6). Used by CI's tls-* jobs and by
# developers running the TLS suite locally. Everything lands in the directory
# given as $1 (default: this script's dir /generated) and is gitignored.
#
#   ca.crt      what clients pass as sslrootcert (PGGQL_TEST_SSLROOTCERT)
#   server.crt  } what the Postgres server is configured with; CN/SAN is
#   server.key  } "localhost" so sslmode=verify-full passes against 127.0.0.1
#                 via the localhost name -- connect with host=localhost.
set -euo pipefail

out="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generated"}"
mkdir -p "$out"
cd "$out"

# CA
openssl req -new -x509 -days 2 -nodes \
  -subj "/CN=pg-gql test CA" \
  -keyout ca.key -out ca.crt 2>/dev/null

# Server key + CSR + CA-signed cert, SAN=localhost (verify-full matches the
# host name the client dialed against the SAN list). The SAN goes in via
# -extfile at signing time: portable across OpenSSL and LibreSSL (macOS),
# unlike -copy_extensions.
openssl req -new -nodes \
  -subj "/CN=localhost" \
  -keyout server.key -out server.csr 2>/dev/null
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > san.ext
openssl x509 -req -in server.csr -days 2 \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -extfile san.ext \
  -out server.crt 2>/dev/null
rm -f server.csr ca.srl san.ext

# Postgres refuses a key that is group/world-readable (unless root-owned with
# 0640); 0600 satisfies every case, container mounts included.
chmod 0600 server.key
chmod 0644 ca.crt server.crt

echo "TLS fixture certs written to $out"
