#!/usr/bin/env bash
# =====================================================================
# Arnes de UPGRADE: prova a atomicidade e o backfill da 0008.
#
# O run_local.sh aplica todas as migracoes antes de existir qualquer
# usuario, entao la o backfill nunca roda. Aqui a ordem e a real de um
# upgrade, e no meio dela injetamos uma falha de proposito:
#
#   ambiente -> 0001..0007 -> dados -> FALHA -> prova de rollback
#            -> 0008 de novo -> prova de backfill
#
#   ./supabase/tests/run_households_backfill.sh
#   PGTEST_PARENT=/caminho/pai ./supabase/tests/run_households_backfill.sh
#
# PGTEST_PARENT e apenas o diretorio PAI. O runner cria dentro dele um
# subdiretorio proprio e so remove esse filho — nunca o pai.
# =====================================================================
set -euo pipefail

BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIXO=ass-finance-pgtest

# =====================================================================
# Contrato do diretorio descartavel (identico ao de run_local.sh)
#
# Uma variavel vinda de fora nunca e alvo direto de `rm -rf`. O operador
# informa so o PAI; o filho e criado aqui, marcado com um valor desta
# execucao, e a remocao so acontece se o caminho ainda casar com
# pai+prefixo E o marcador continuar com o mesmo valor.
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
trap limpar EXIT

mkdir -p -- "$DIR/data" "$DIR/run" "$DIR/log"
if [ "$(id -u)" = 0 ]; then
  chmod 0711 -- "$DIR"
  chown -R postgres:postgres -- "$DIR/data" "$DIR/run" "$DIR/log"
fi

# rodar_migracao usa -1: o arquivo inteiro vira UMA transacao. rodar_sql nao,
# porque os arquivos de teste administram a propria transacao.
rodar_sql() {
  como_pg "$BIN/psql" -h "$DIR/run" -U postgres -v ON_ERROR_STOP=1 -q -f "$1"
}
rodar_migracao() {
  como_pg "$BIN/psql" -h "$DIR/run" -U postgres -1 -v ON_ERROR_STOP=1 -q -f "$1"
}

MIG_0008="$RAIZ/supabase/migrations/0008_households_fundacao.sql"
LOG_FALHA="$DIR/log/falha-esperada.log"

echo "diretorio descartavel: $DIR"
como_pg "$BIN/initdb" -D "$DIR/data" -U postgres --auth=trust > "$DIR/log/initdb.log"
como_pg "$BIN/pg_ctl" -D "$DIR/data" \
  -o "-c listen_addresses='' -c unix_socket_directories='$DIR/run'" \
  -l "$DIR/log/server.log" start -w

echo "→ ambiente (auth, papeis, auth.uid())"
rodar_sql "$RAIZ/supabase/tests/_ambiente_local.sql"

echo "→ migracoes 0001 a 0007, cada uma em transacao de arquivo"
for m in "$RAIZ"/supabase/migrations/000[1-7]_*.sql; do
  echo "   $(basename "$m")"
  rodar_migracao "$m"
done

echo "→ dados preexistentes (A/B reciprocos, C unilateral, D isolado)"
rodar_sql "$RAIZ/supabase/tests/households_backfill_setup.sql"

# ------------------------------------------------- atomicidade
echo "→ armando a falha injetada em public.cartoes"
rodar_sql "$RAIZ/supabase/tests/households_atomicity_fault.sql"

echo "→ 0008 com falha injetada: DEVE falhar e desfazer tudo"
if rodar_migracao "$MIG_0008" > "$LOG_FALHA" 2>&1; then
  echo "ERRO DO ARNES: a 0008 teve sucesso, mas a falha injetada deveria te-la derrubado." >&2
  exit 1
fi
if ! grep -q 'FALHA_INJETADA_0008' "$LOG_FALHA"; then
  echo "ERRO DO ARNES: a 0008 falhou, mas nao pela falha injetada. Saida capturada:" >&2
  sed 's/^/     /' "$LOG_FALHA" >&2
  exit 1
fi
echo "   falha esperada e confirmada: $(grep -m1 'FALHA_INJETADA_0008' "$LOG_FALHA" | sed 's/^psql:[^ ]* //')"
echo "   (saida completa em $LOG_FALHA — falha ESPERADA, nao falha do arnes)"

echo "→ provando que o rollback nao deixou residuo"
rodar_sql "$RAIZ/supabase/tests/households_atomicity_test.sql"

echo "→ desarmando a falha injetada"
como_pg "$BIN/psql" -h "$DIR/run" -U postgres -v ON_ERROR_STOP=1 -q \
  -c 'drop trigger if exists trg_falha_injetada on public.cartoes;' \
  -c 'drop function if exists teste_backfill.falha_injetada();'

# ------------------------------------------------- caminho feliz
echo "→ 0008 de novo, agora sem obstaculo"
rodar_migracao "$MIG_0008"

echo "→ verificacao do backfill"
rodar_sql "$RAIZ/supabase/tests/households_backfill_test.sql"
