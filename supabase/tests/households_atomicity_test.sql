-- =====================================================================
-- Prova NEGATIVA: depois de a 0008 falhar no meio, o banco tem de estar
-- exatamente como estava antes da tentativa.
--
-- Roda logo apos a falha injetada, com o gatilho de falha ainda instalado.
-- Compara com as fotografias tiradas pelo setup, antes de tudo.
-- =====================================================================

do $$
declare
  n bigint;
  t text;
begin
  raise notice 'Atomicidade da 0008 (apos falha injetada):';

  -- 1 e 2: as tabelas da fundacao nao chegaram a existir
  perform teste_backfill.assert(to_regclass('public.households') is null,
    'rollback: public.households nao existe');
  perform teste_backfill.assert(to_regclass('public.household_members') is null,
    'rollback: public.household_members nao existe');

  -- 3: nenhuma coluna household_id sobrou nas quatro tabelas
  select count(*) into n from information_schema.columns
   where table_schema = 'public'
     and table_name in ('contas', 'cartoes', 'categorias', 'lancamentos')
     and column_name = 'household_id';
  perform teste_backfill.assert(n = 0,
    'rollback: nenhuma das quatro tabelas ficou com household_id');

  -- 4 e 5: as funcoes novas nao sobreviveram
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'household_de';
  perform teste_backfill.assert(n = 0, 'rollback: app.household_de(uuid) nao existe');

  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'deriva_household';
  perform teste_backfill.assert(n = 0, 'rollback: app.deriva_household() nao existe');

  -- 6: os carimbos voltaram a existir E a estar habilitados. Este e o
  --    ponto mais fino: a 0008 os desabilita no meio do backfill, entao
  --    tgenabled='O' aqui prova que o `disable trigger` tambem foi desfeito.
  select count(*) into n from pg_trigger
   where tgname = 'trg_atualizado_em'
     and tgrelid in ('public.contas'::regclass, 'public.cartoes'::regclass,
                     'public.categorias'::regclass, 'public.lancamentos'::regclass)
     and tgenabled = 'O';
  perform teste_backfill.assert(n = 4,
    'rollback: os quatro trg_atualizado_em continuam presentes e HABILITADOS');

  -- 7: nenhuma linha criada, perdida ou alterada em contagem
  select count(*) into n from teste_backfill.contagem_antes ca
    join (select 'contas' as tabela, count(*) from public.contas
          union all select 'cartoes', count(*) from public.cartoes
          union all select 'categorias', count(*) from public.categorias
          union all select 'lancamentos', count(*) from public.lancamentos) cd
      on cd.tabela = ca.tabela and cd.count = ca.count;
  perform teste_backfill.assert(n = 4,
    'rollback: contagem das quatro tabelas identica a fotografia anterior');

  -- 8: o vinculo permanece intocado
  select count(*) into n from (
    (select id, parceiro_id from public.usuarios
     except
     select id, parceiro_id from teste_backfill.parceiro_antes)
    union all
    (select id, parceiro_id from teste_backfill.parceiro_antes
     except
     select id, parceiro_id from public.usuarios)
  ) x;
  perform teste_backfill.assert(n = 0,
    'rollback: usuarios.parceiro_id identico a fotografia anterior');
end $$;

do $$ begin raise notice E'\nAtomicidade verificada: a falha nao deixou residuo.'; end $$;
