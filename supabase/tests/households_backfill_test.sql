-- =====================================================================
-- Verifica o backfill da 0008 sobre dados que ja existiam.
-- Roda DEPOIS da 0008, no mesmo banco descartavel do setup.
-- Prova estado final, nao apenas excecao.
-- =====================================================================

\set A '11111111-1111-4111-8111-111111111111'
\set B '22222222-2222-4222-8222-222222222222'
\set C '33333333-3333-4333-8333-333333333333'
\set D '44444444-4444-4444-8444-444444444444'

do $$
declare
  a_id constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id constant uuid := '22222222-2222-4222-8222-222222222222';
  c_id constant uuid := '33333333-3333-4333-8333-333333333333';
  d_id constant uuid := '44444444-4444-4444-8444-444444444444';
  h_a uuid; h_b uuid; h_c uuid; h_d uuid;
  p_a smallint; p_b smallint; p_c smallint; p_d smallint;
  n bigint;
begin
  raise notice 'Backfill da 0008 sobre dados preexistentes:';

  select household_id, posicao into h_a, p_a from public.household_members where usuario_id = a_id;
  select household_id, posicao into h_b, p_b from public.household_members where usuario_id = b_id;
  select household_id, posicao into h_c, p_c from public.household_members where usuario_id = c_id;
  select household_id, posicao into h_d, p_d from public.household_members where usuario_id = d_id;

  -- ------------------------------------------------ par reciproco
  perform teste_backfill.assert(h_a is not null and h_a = h_b,
    'A e B (parceiro_id reciproco) caem no mesmo household');
  perform teste_backfill.assert(p_a = 1 and p_b = 2,
    'posicoes 1 e 2 atribuidas de forma estavel (menor id fica com a 1)');

  -- --------------------------------- unilateral e isolado, separados
  perform teste_backfill.assert(h_c is not null and h_c <> h_a,
    'C (aponta para A sem reciprocidade) NAO entra no household do par');
  perform teste_backfill.assert(h_d is not null and h_d <> h_a,
    'D (sem parceiro) NAO entra no household do par');
  perform teste_backfill.assert(h_c <> h_d,
    'C e D ficam em households individuais diferentes entre si');
  perform teste_backfill.assert(p_c = 1 and p_d = 1,
    'C e D ocupam a posicao 1 dos proprios grupos');

  -- ------------------------------------- exatamente uma membresia
  select count(*) into n from public.usuarios u
   where not exists (select 1 from public.household_members hm where hm.usuario_id = u.id);
  perform teste_backfill.assert(n = 0, 'nenhum usuario ficou sem membresia');

  select count(*) into n from public.household_members;
  perform teste_backfill.assert(n = 4, 'exatamente 4 membresias, uma por usuario');

  select count(*) into n from public.households;
  perform teste_backfill.assert(n = 3, 'exatamente 3 households: o par, o C e o D');

  -- ------------------- entidades preexistentes herdaram o household
  select count(*) into n from public.contas e
    join public.household_members hm on hm.usuario_id = e.usuario_id
   where e.household_id is distinct from hm.household_id;
  perform teste_backfill.assert(n = 0, 'toda conta preexistente tem o household do dono');

  select count(*) into n from public.cartoes e
    join public.household_members hm on hm.usuario_id = e.usuario_id
   where e.household_id is distinct from hm.household_id;
  perform teste_backfill.assert(n = 0, 'todo cartao preexistente tem o household do dono');

  select count(*) into n from public.categorias e
    join public.household_members hm on hm.usuario_id = e.usuario_id
   where e.household_id is distinct from hm.household_id;
  perform teste_backfill.assert(n = 0, 'toda categoria preexistente tem o household do dono');

  select count(*) into n from public.lancamentos e
    join public.household_members hm on hm.usuario_id = e.usuario_id
   where e.household_id is distinct from hm.household_id;
  perform teste_backfill.assert(n = 0, 'todo lancamento preexistente tem o household do dono');

  -- A e B compartilham household, entao as entidades dos dois apontam
  -- para o mesmo grupo — o que e o ponto da fundacao.
  select count(distinct household_id) into n from public.contas
   where usuario_id in (a_id, b_id);
  perform teste_backfill.assert(n = 1, 'as contas de A e de B apontam para o mesmo household');

  -- --------------------------- nenhuma entidade perdida ou criada
  select count(*) into n from teste_backfill.contagem_antes ca
    join (select 'contas' as tabela, count(*) from public.contas
          union all select 'cartoes', count(*) from public.cartoes
          union all select 'categorias', count(*) from public.categorias
          union all select 'lancamentos', count(*) from public.lancamentos) cd
      on cd.tabela = ca.tabela and cd.count = ca.count;
  perform teste_backfill.assert(n = 4, 'contagem das quatro tabelas inalterada pelo backfill');

  -- ------------------------------- parceiro_id nao foi tocado
  select count(*) into n from (
    select id, parceiro_id from public.usuarios
    except
    select id, parceiro_id from teste_backfill.parceiro_antes
  ) x;
  perform teste_backfill.assert(n = 0, 'parceiro_id de todo usuario continua identico ao estado anterior');

  select count(*) into n from (
    select id, parceiro_id from teste_backfill.parceiro_antes
    except
    select id, parceiro_id from public.usuarios
  ) x;
  perform teste_backfill.assert(n = 0, 'nenhum vinculo anterior desapareceu');
end $$;

-- =====================================================================
-- Limites de membresia: terceira posicao e segunda membresia
-- =====================================================================
do $$
declare
  h_par uuid;
  e_id  constant uuid := '55555555-5555-4555-8555-555555555555';
  n bigint;
begin
  raise notice 'Limites de membresia:';

  select household_id into h_par from public.household_members
   where usuario_id = '11111111-1111-4111-8111-111111111111';

  -- um quinto usuario, para tentar entrar num grupo ja cheio
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', e_id, 'authenticated', 'authenticated',
          'e@teste.local', '', now(), now(), now(), '{}'::jsonb, '{"nome":"Usuario E"}'::jsonb);

  -- E ja nasce com household proprio pelo provisionamento da 0008
  select count(*) into n from public.household_members where usuario_id = e_id;
  perform teste_backfill.assert(n = 1,
    'usuario criado DEPOIS da 0008 ja nasce com uma membresia');

  -- terceira posicao no grupo do casal: 'posicao' so aceita 1 e 2
  begin
    insert into public.household_members (household_id, usuario_id, posicao)
    values (h_par, e_id, 3);
    perform teste_backfill.assert(false, 'posicao 3 nao deveria ser aceita');
  exception when check_violation then
    perform teste_backfill.assert(true, 'posicao 3 recusada pelo CHECK');
  end;

  -- reocupar a posicao 2 do grupo cheio: indice unico, seguro sob concorrencia
  begin
    insert into public.household_members (household_id, usuario_id, posicao)
    values (h_par, e_id, 2);
    perform teste_backfill.assert(false, 'a posicao 2 ja esta ocupada');
  exception when unique_violation then
    perform teste_backfill.assert(true, 'terceiro membro recusado: posicao 2 ja ocupada (indice unico)');
  end;

  -- segunda membresia do mesmo usuario, em qualquer grupo
  begin
    insert into public.household_members (household_id, usuario_id, posicao)
    values (h_par, '44444444-4444-4444-8444-444444444444', 1);
    perform teste_backfill.assert(false, 'D nao deveria ganhar uma segunda membresia');
  exception when unique_violation then
    perform teste_backfill.assert(true, 'segunda membresia do mesmo usuario recusada (unique em usuario_id)');
  end;

  select count(*) into n from public.household_members where household_id = h_par;
  perform teste_backfill.assert(n = 2, 'ESTADO FINAL: o grupo do casal continua com exatamente 2 membros');

  select count(*) into n from public.household_members
   where usuario_id = '44444444-4444-4444-8444-444444444444';
  perform teste_backfill.assert(n = 1, 'ESTADO FINAL: D continua com exatamente uma membresia');
end $$;

do $$ begin raise notice E'\nBackfill verificado.'; end $$;
