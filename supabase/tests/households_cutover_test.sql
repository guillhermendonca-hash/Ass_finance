-- =====================================================================
-- Verifica a reconciliacao e o cutover da 0009.
-- Roda DEPOIS da 0009, no mesmo banco descartavel.
-- Prova estado final, nao apenas ausencia de excecao.
-- =====================================================================
do $$
declare
  a_id constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id constant uuid := '22222222-2222-4222-8222-222222222222';
  c_id constant uuid := '33333333-3333-4333-8333-333333333333';
  d_id constant uuid := '44444444-4444-4444-8444-444444444444';
  e_id constant uuid := '55555555-5555-4555-8555-555555555555';
  h_a uuid; h_b uuid; h_c uuid; h_d uuid; h_e uuid;
  p_c smallint; p_d smallint;
  n bigint;
  t text;
begin
  raise notice 'Cutover da 0009 — reconciliacao:';

  select household_id into h_a from public.household_members where usuario_id = a_id;
  select household_id into h_b from public.household_members where usuario_id = b_id;
  select household_id, posicao into h_c, p_c from public.household_members where usuario_id = c_id;
  select household_id, posicao into h_d, p_d from public.household_members where usuario_id = d_id;
  select household_id into h_e from public.household_members where usuario_id = e_id;

  -- ------------------------------------- o par desfeito foi separado
  perform teste_backfill.assert(h_a is not null and h_b is not null and h_a <> h_b,
    'A e B, que deixaram de ser reciprocos, foram separados em households individuais');
  select count(*) into n from public.household_members where household_id = h_a;
  perform teste_backfill.assert(n = 1, 'o household de A ficou individual');
  select count(*) into n from public.household_members where household_id = h_b;
  perform teste_backfill.assert(n = 1, 'o household de B ficou individual');

  -- ------------------------------------- o par novo foi unido
  perform teste_backfill.assert(h_c is not null and h_c = h_d,
    'C e D, agora reciprocos, foram unidos no mesmo household');
  perform teste_backfill.assert(
    (case when c_id < d_id then p_c = 1 and p_d = 2 else p_c = 2 and p_d = 1 end),
    'as posicoes de C e D seguem a ordem estavel por uuid');

  -- ------------------------------------- o isolado nao se mexeu
  perform teste_backfill.assert(h_e is not null and h_e <> h_c and h_e <> h_a and h_e <> h_b,
    'E permaneceu em household individual proprio');

  -- ------------------------------ uma membresia por usuario, teto 2
  select count(*) into n from public.usuarios u
   where not exists (select 1 from public.household_members hm where hm.usuario_id = u.id);
  perform teste_backfill.assert(n = 0, 'todo usuario tem membresia');

  select count(*) into n
    from (select usuario_id from public.household_members group by usuario_id having count(*) > 1) x;
  perform teste_backfill.assert(n = 0, 'nenhum usuario tem duas membresias');

  select count(*) into n
    from (select household_id from public.household_members group by household_id having count(*) > 2) x;
  perform teste_backfill.assert(n = 0, 'nenhum household passou de dois membros');

  -- ------------------------- entidades no household atual do dono
  foreach t in array array['contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format(
      'select count(*) from public.%I e
         join public.household_members hm on hm.usuario_id = e.usuario_id
        where e.household_id is distinct from hm.household_id', t) into n;
    perform teste_backfill.assert(n = 0,
      format('toda linha de %s aponta para o household atual do dono', t));
  end loop;

  -- ------------------ nada de dono, linha ou parceiro_id mudou
  -- EXCEPT nos dois sentidos. Os parenteses em volta do UNION ALL sao
  -- obrigatorios: sem eles o EXCEPT associa a esquerda e compara so com a
  -- primeira tabela.
  select count(*) into n from (
    (select tabela, id, usuario_id from teste_cutover.entidades_antes
     except
     (select 'contas'::text, id, usuario_id from public.contas
      union all select 'cartoes', id, usuario_id from public.cartoes
      union all select 'categorias', id, usuario_id from public.categorias
      union all select 'lancamentos', id, usuario_id from public.lancamentos))
    union all
    ((select 'contas'::text, id, usuario_id from public.contas
      union all select 'cartoes', id, usuario_id from public.cartoes
      union all select 'categorias', id, usuario_id from public.categorias
      union all select 'lancamentos', id, usuario_id from public.lancamentos)
     except
     select tabela, id, usuario_id from teste_cutover.entidades_antes)
  ) x;
  perform teste_backfill.assert(n = 0,
    'nenhuma linha mudou de dono, sumiu ou apareceu durante a reconciliacao');

  select count(*) into n from (
    (select id, parceiro_id from public.usuarios
     except select id, parceiro_id from teste_cutover.parceiro_antes)
    union all
    (select id, parceiro_id from teste_cutover.parceiro_antes
     except select id, parceiro_id from public.usuarios)
  ) x;
  perform teste_backfill.assert(n = 0,
    'a reconciliacao nao tocou em usuarios.parceiro_id');

  select count(*) into n from teste_cutover.contagem_antes ca
    join (select 'contas'::text as tabela, count(*) from public.contas
          union all select 'cartoes', count(*) from public.cartoes
          union all select 'categorias', count(*) from public.categorias
          union all select 'lancamentos', count(*) from public.lancamentos
          union all select 'usuarios', count(*) from public.usuarios) cd
      on cd.tabela = ca.tabela and cd.count = ca.count;
  perform teste_backfill.assert(n = 5, 'contagens das cinco tabelas inalteradas');

  -- --------------------------------- carimbos preservados
  select count(*) into n
  from teste_cutover.entidades_antes a
  join (select 'contas'::text as tabela, id, atualizado_em from public.contas
        union all select 'cartoes', id, atualizado_em from public.cartoes
        union all select 'categorias', id, atualizado_em from public.categorias
        union all select 'lancamentos', id, atualizado_em from public.lancamentos) d
    on d.tabela = a.tabela and d.id = a.id
  where d.atualizado_em is distinct from a.atualizado_em;
  perform teste_backfill.assert(n = 0,
    'atualizado_em preservado: a troca foi estrutural, nao edicao do usuario');

  -- ------------------------- nenhum household antigo orfao
  select count(*) into n
  from teste_cutover.households_antes ha
  where exists (select 1 from public.households h where h.id = ha.id);
  perform teste_backfill.assert(n = 0,
    'nenhum household anterior ao cutover permaneceu');

  select count(*) into n
  from public.households h
  where not exists (select 1 from public.household_members hm where hm.household_id = h.id);
  perform teste_backfill.assert(n = 0, 'nenhum household ficou sem membro');
end $$;

-- =====================================================================
-- A autoridade agora e a membresia, nao o ponteiro
-- =====================================================================
do $$
declare
  a_id constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id constant uuid := '22222222-2222-4222-8222-222222222222';
  c_id constant uuid := '33333333-3333-4333-8333-333333333333';
  d_id constant uuid := '44444444-4444-4444-8444-444444444444';
  ptr uuid;
begin
  raise notice 'Autoridade por membresia:';

  -- B ainda aponta para A (ponteiro obsoleto), mas nao dividem household
  select parceiro_id into ptr from public.usuarios where id = b_id;
  perform teste_backfill.assert(ptr = a_id,
    'B continua com o ponteiro obsoleto apontando para A');
  perform teste_backfill.assert(not app.sao_parceiros(a_id, b_id),
    'app.sao_parceiros ignora o ponteiro unilateral obsoleto de B para A');
  perform teste_backfill.assert(not app.sao_parceiros(b_id, a_id),
    'e ignora nos dois sentidos');

  perform teste_backfill.assert(app.sao_parceiros(c_id, d_id),
    'app.sao_parceiros reconhece C e D pela membresia');
  perform teste_backfill.assert(not app.sao_parceiros(c_id, c_id),
    'ninguem e parceiro de si mesmo');

  -- parceiro_atual depende de auth.uid()
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', b_id), true);
  perform teste_backfill.assert(app.parceiro_atual() is null,
    'app.parceiro_atual() de B e null: ponteiro obsoleto nao inventa parceiro');

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', c_id), true);
  perform teste_backfill.assert(app.parceiro_atual() = d_id,
    'app.parceiro_atual() de C devolve D, pela membresia');
end $$;

-- =====================================================================
-- Catalogo: parceiro_id nao pode estar em fronteira de autorizacao
-- =====================================================================
do $$
declare
  n bigint;
  achados text;
begin
  raise notice 'Allowlist de parceiro_id:';

  select count(*), coalesce(string_agg(p.proname, ', '), '')
    into n, achados
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'app'
    and p.proname in ('sao_parceiros', 'parceiro_atual', 'valida_vinculos_lancamento',
                      'household_de', 'deriva_household')
    and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform teste_backfill.assert(n = 0,
    'nenhum helper de autorizacao menciona parceiro_id' ||
    case when n > 0 then ' (achados: ' || achados || ')' else '' end);

  select count(*), coalesce(string_agg(p.proname, ', '), '')
    into n, achados
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('resumo_do_parceiro', 'saldos_agregados_do_parceiro')
    and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform teste_backfill.assert(n = 0,
    'nenhuma funcao agregadora menciona parceiro_id' ||
    case when n > 0 then ' (achados: ' || achados || ')' else '' end);

  select count(*), coalesce(string_agg(policyname, ', '), '')
    into n, achados
  from pg_policies
  where schemaname = 'public'
    and (coalesce(qual, '') like '%parceiro_id%' or coalesce(with_check, '') like '%parceiro_id%');
  perform teste_backfill.assert(n = 0,
    'nenhuma policy menciona parceiro_id' ||
    case when n > 0 then ' (achados: ' || achados || ')' else '' end);

  -- e as tres RPCs de vinculo PODEM usar: e la que mora a solicitacao
  select count(*) into n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('meu_parceiro', 'vincular_parceiro', 'desvincular_parceiro')
    and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform teste_backfill.assert(n = 3,
    'as tres RPCs de vinculo continuam usando parceiro_id como estado de solicitacao');
end $$;

do $$ begin raise notice E'\nCutover verificado.'; end $$;
