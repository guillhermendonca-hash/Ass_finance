#!/usr/bin/env bash
# =====================================================================
# Arnes de UPGRADE: prova o backfill da 0008 sobre dados preexistentes.
#
# O run_local.sh aplica todas as migracoes antes de existir qualquer
# usuario, entao la o household vem do provisionamento e o backfill nunca
# roda. Aqui a ordem e a real de um upgrade:
#
#   ambiente -> 0001..0007 -> dados -> 0008 -> verificacao
#
#   ./supabase/tests/run_households_backfill.sh
#   PGTEST_DIR=/caminho/proprio ./supabase/tests/run_households_backfill.sh
# =====================================================================
set -euo pipefail

BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DIR=${PGTEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/households-backfill.XXXXXX")}

# --------------------------------------------------------------- guardas
# O teardown faz remocao recursiva. Antes de aceitar o alvo, exigimos que
# ele seja um caminho absoluto, profundo e fora das raizes perigosas.
validar_alvo() {
  local alvo="$1"
  [ -n "$alvo" ]                        || { echo "PGTEST_DIR vazio"; exit 2; }
  [ "${alvo#/}" != "$alvo" ]            || { echo "PGTEST_DIR precisa ser caminho absoluto: $alvo"; exit 2; }
  case "$alvo" in
    /|/root|/home|/home/*/|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/bin|/bin/*|/lib|/lib/*)
      echo "PGTEST_DIR aponta para caminho protegido: $alvo"; exit 2;;
  esac
  [ "$alvo" != "${HOME:-/nao-existe}" ] || { echo "PGTEST_DIR nao pode ser o HOME"; exit 2; }
  # ao menos dois niveis: /tmp/x, nunca /tmp sozinho
  [ "$(printf '%s' "$alvo" | tr -cd / | wc -c)" -ge 2 ] || { echo "PGTEST_DIR raso demais: $alvo"; exit 2; }
}
validar_alvo "$DIR"

mkdir -p "$DIR/data" "$DIR/run"
if [ "$(id -u)" = 0 ]; then chown -R postgres:postgres "$DIR"; COMO="su postgres -c"; else COMO="bash -c"; fi

limpar() {
  $COMO "$BIN/pg_ctl -D $DIR/data stop -m immediate" >/dev/null 2>&1 || true
  validar_alvo "$DIR"
  rm -rf "$DIR"
}
trap limpar EXIT

echo "diretorio descartavel: $DIR"
$COMO "$BIN/initdb -D $DIR/data -U postgres --auth=trust" > "$DIR/init.log"
$COMO "$BIN/pg_ctl -D $DIR/data -o \"-k $DIR/run -c listen_addresses=''\" -l $DIR/server.log start -w"

rodar() { $COMO "$BIN/psql -h $DIR/run -U postgres -v ON_ERROR_STOP=1 -q -f $1"; }

echo "→ ambiente (auth, papeis, auth.uid())"
rodar "$RAIZ/supabase/tests/_ambiente_local.sql"

echo "→ migracoes 0001 a 0007 (estado ANTES da fundacao)"
for m in "$RAIZ"/supabase/migrations/000[1-7]_*.sql; do
  echo "   $(basename "$m")"
  rodar "$m"
done

echo "→ dados preexistentes (A/B reciprocos, C unilateral, D isolado)"
rodar "$RAIZ/supabase/tests/households_backfill_setup.sql"

echo "→ 0008: fundacao e backfill"
rodar "$RAIZ/supabase/migrations/0008_households_fundacao.sql"

echo "→ verificacao"
rodar "$RAIZ/supabase/tests/households_backfill_test.sql"
