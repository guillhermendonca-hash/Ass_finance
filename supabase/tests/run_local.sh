#!/usr/bin/env bash
# =====================================================================
# Sobe um Postgres descartavel, aplica as migracoes e roda o teste de RLS.
#
#   ./supabase/tests/run_local.sh
#   PGTEST_PARENT=/caminho/pai ./supabase/tests/run_local.sh
#
# PGTEST_PARENT e apenas o diretorio PAI. O runner cria dentro dele um
# subdiretorio proprio e so remove esse filho — nunca o pai. Ver o
# contrato logo abaixo.
# =====================================================================
set -euo pipefail

BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIXO=ass-finance-pgtest

# =====================================================================
# Contrato do diretorio descartavel
#
# Uma variavel vinda de fora nunca e alvo direto de `rm -rf`. O que o
# operador informa e so o PAI; o filho e criado aqui, marcado com um valor
# desta execucao, e a remocao so acontece se, na hora do cleanup, o caminho
# ainda casar com pai+prefixo E o marcador continuar com o mesmo valor.
# Qualquer divergencia preserva o diretorio e avisa.
# =====================================================================
como_pg() {
  if [ "$(id -u)" = 0 ]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u postgres -- "$@"
    else
      # o '--' impede que o su interprete as flags do comando alvo
      su postgres -c 'exec "$@"' -- bash "$@"
    fi
  else
    "$@"
  fi
}

PARENT_INFORMADO=${PGTEST_PARENT:-${TMPDIR:-/tmp}}

case "$PARENT_INFORMADO" in
  /*) ;;
  *) echo "recusado: PGTEST_PARENT precisa ser caminho absoluto: $PARENT_INFORMADO" >&2; exit 2 ;;
esac
if [ ! -d "$PARENT_INFORMADO" ]; then
  echo "recusado: PGTEST_PARENT nao existe ou nao e diretorio: $PARENT_INFORMADO" >&2
  exit 2
fi
# forma canonica: resolve links simbolicos e '..' antes de qualquer uso
PARENT=$(cd -- "$PARENT_INFORMADO" && pwd -P)

# Rodando como root, o Postgres roda como 'postgres': ele precisa atravessar
# o pai. O runner NAO mexe no diretorio do operador — recusa e diz o que fazer.
if [ "$(id -u)" = 0 ] && ! como_pg /usr/bin/test -x "$PARENT"; then
  echo "recusado: o usuario postgres nao consegue atravessar PGTEST_PARENT: $PARENT" >&2
  echo "          ajuste com  chmod o+x -- '$PARENT'  ou escolha outro pai." >&2
  exit 2
fi

DIR=$(mktemp -d -- "$PARENT/$PREFIXO.XXXXXX")
MARCA="$DIR/.posse"
TOKEN="$PREFIXO:$$:$(date +%s):${RANDOM}${RANDOM}"
printf '%s\n' "$TOKEN" > "$MARCA"

parar_postgres() {
  [ -d "$DIR/data" ] || return 0
  como_pg "$BIN/pg_ctl" -D "$DIR/data" stop -m immediate >/dev/null 2>&1 || true
}

limpar() {
  parar_postgres
  case "$DIR" in
    "$PARENT/$PREFIXO."??????) ;;
    *) echo "cleanup recusado: caminho fora do contrato. Preservado: $DIR" >&2; return 0 ;;
  esac
  if [ ! -f "$MARCA" ]; then
    echo "cleanup recusado: marcador de posse ausente. Preservado: $DIR" >&2; return 0
  fi
  if [ "$(cat -- "$MARCA")" != "$TOKEN" ]; then
    echo "cleanup recusado: marcador de posse divergente. Preservado: $DIR" >&2; return 0
  fi
  rm -rf -- "$DIR"
}
# o trap entra ANTES do initdb: se a inicializacao falhar, o filho ja sai junto
trap limpar EXIT

mkdir -p -- "$DIR/data" "$DIR/run" "$DIR/log"
if [ "$(id -u)" = 0 ]; then
  # o pai fica atravessavel, mas nao listavel; o marcador segue do root
  chmod 0711 -- "$DIR"
  chown -R postgres:postgres -- "$DIR/data" "$DIR/run" "$DIR/log"
fi

# --------------------------------------------------------------- psql
# rodar_migracao usa -1: o arquivo inteiro vira UMA transacao, entao uma
# falha no meio desfaz tudo, inclusive DDL e `disable trigger`.
# rodar_sql NAO usa -1, porque os arquivos de teste administram a propria
# transacao (rls_test.sql abre BEGIN e termina em ROLLBACK).
rodar_sql() {
  como_pg "$BIN/psql" -h "$DIR/run" -U postgres -v ON_ERROR_STOP=1 -q -f "$1"
}
rodar_migracao() {
  como_pg "$BIN/psql" -h "$DIR/run" -U postgres -1 -v ON_ERROR_STOP=1 -q -f "$1"
}

echo "diretorio descartavel: $DIR"
como_pg "$BIN/initdb" -D "$DIR/data" -U postgres --auth=trust > "$DIR/log/initdb.log"
como_pg "$BIN/pg_ctl" -D "$DIR/data" \
  -o "-c listen_addresses='' -c unix_socket_directories='$DIR/run'" \
  -l "$DIR/log/server.log" start -w

rodar_sql "$RAIZ/supabase/tests/_ambiente_local.sql"
for m in "$RAIZ"/supabase/migrations/*.sql; do
  echo "→ $(basename "$m")"
  rodar_migracao "$m"
done
echo
rodar_sql "$RAIZ/supabase/tests/rls_test.sql"
