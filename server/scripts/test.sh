#!/bin/sh
# Runs the server's real test suite: the pure-unit tests AND the DB-backed handler tests.
#
# Those handler tests exercise the actual chi router, handlers and queries against a real
# Postgres (see internal/api/harness_test.go). Without a database they skip themselves, and a
# skipped suite still prints "ok" - which is how a scan-order bug once survived a clean local
# run. This script removes the excuse: it starts a throwaway Postgres, points the tests at
# it, and takes it down again whatever happens.
#
# Anything passed to this script goes through to `go test`, so the usual filters work:
#
#     server/scripts/test.sh ./internal/api/ -run TestFeed -v
set -e

cd "$(dirname "$0")/.."

CONTAINER=checkin-test-postgres-$$
PORT=${CHECKIN_TEST_PG_PORT:-55432}
PASSWORD=test-$$

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run the DB-backed tests." >&2
  echo "To run only the pure-unit tests instead: CHECKIN_SKIP_DB_TESTS=1 go test ./..." >&2
  exit 1
fi

echo "starting a throwaway Postgres on port $PORT..." >&2
docker run -d --name "$CONTAINER" \
  -e POSTGRES_USER=checkin \
  -e POSTGRES_PASSWORD="$PASSWORD" \
  -e POSTGRES_DB=checkin_test \
  -p "$PORT":5432 postgres:16-alpine >/dev/null

# Wait for it to accept connections rather than sleeping a guessed number of seconds.
i=0
until docker exec "$CONTAINER" pg_isready -U checkin >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "Postgres did not become ready in 60s" >&2
    exit 1
  fi
  sleep 1
done

# -race matches what CI runs, so a data race fails here rather than only there.
TESTDB_URL="postgres://checkin:$PASSWORD@127.0.0.1:$PORT/checkin_test?sslmode=disable" \
  go test -race "${@:-./...}"
