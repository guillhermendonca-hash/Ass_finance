#!/usr/bin/env bash
# Sobe um Postgres descartável, aplica as migrações e roda o teste de RLS.
#   ./supabase/tests/run_local.sh
set -euo pipefail

BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
DIR=${PGTEST_DIR:-/tmp/pgtest}
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"

rm -rf "$DIR"; mkdir -p "$DIR/data" "$DIR/run"
if [ "$(id -u)" = 0 ]; then chown -R postgres:postgres "$DIR"; COMO="su postgres -c"; else COMO="bash -c"; fi

$COMO "$BIN/initdb -D $DIR/data -U postgres --auth=trust" > "$DIR/init.log"
$COMO "$BIN/pg_ctl -D $DIR/data -o \"-k $DIR/run -c listen_addresses=''\" -l $DIR/server.log start -w"
trap '$COMO "$BIN/pg_ctl -D $DIR/data stop -m immediate" >/dev/null 2>&1 || true' EXIT

rodar() { $COMO "$BIN/psql -h $DIR/run -U postgres -v ON_ERROR_STOP=1 -q -f $1"; }

rodar "$RAIZ/supabase/tests/_ambiente_local.sql"
for m in "$RAIZ"/supabase/migrations/*.sql; do echo "→ $(basename "$m")"; rodar "$m"; done
echo
rodar "$RAIZ/supabase/tests/rls_test.sql"
