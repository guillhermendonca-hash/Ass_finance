-- =====================================================================
-- Cenario aplicado ENTRE a 0007 e a 0008, para exercitar o backfill.
--
-- O arnes normal (rls_test.sql) roda com todas as migracoes ja aplicadas
-- e cria os usuarios depois — ali o household vem do provisionamento, nao
-- do backfill. Este arquivo existe para reproduzir a ordem real de um
-- upgrade: dados primeiro, 0008 depois.
--
--   A e B  -> parceiro_id reciproco   -> devem cair no mesmo household
--   C      -> aponta para A, sem volta -> household individual
--   D      -> sem parceiro             -> household individual
-- =====================================================================

create schema if not exists teste_backfill;

create or replace function teste_backfill.assert(cond boolean, msg text)
returns void language plpgsql as $$
begin
  if not cond then
    raise exception 'FALHOU -> %', msg;
  end if;
  raise notice '  ok  %', msg;
end $$;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111',
   'authenticated', 'authenticated', 'a@teste.local', '', now(), now(), now(),
   '{"provider":"email"}'::jsonb, '{"nome":"Usuario A"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222',
   'authenticated', 'authenticated', 'b@teste.local', '', now(), now(), now(),
   '{"provider":"email"}'::jsonb, '{"nome":"Usuario B"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333',
   'authenticated', 'authenticated', 'c@teste.local', '', now(), now(), now(),
   '{"provider":"email"}'::jsonb, '{"nome":"Usuario C"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-8444-444444444444',
   'authenticated', 'authenticated', 'd@teste.local', '', now(), now(), now(),
   '{"provider":"email"}'::jsonb, '{"nome":"Usuario D"}'::jsonb);

-- A <-> B reciproco; C -> A sem volta; D sem ninguem.
update public.usuarios set parceiro_id = '22222222-2222-4222-8222-222222222222'
 where id = '11111111-1111-4111-8111-111111111111';
update public.usuarios set parceiro_id = '11111111-1111-4111-8111-111111111111'
 where id = '22222222-2222-4222-8222-222222222222';
update public.usuarios set parceiro_id = '11111111-1111-4111-8111-111111111111'
 where id = '33333333-3333-4333-8333-333333333333';

-- Ao menos uma entidade de cada tipo, para cada usuario. As categorias ja
-- vieram do provisionamento de 0005 (13 por usuario).
insert into public.contas (id, usuario_id, nome, saldo_atual, visibilidade)
select ('aa000000-0000-4000-8000-00000000000' || n)::uuid, u.id,
       'Conta ' || u.nome, 100 * n, 'privado'
from (values (1, '11111111-1111-4111-8111-111111111111'::uuid),
             (2, '22222222-2222-4222-8222-222222222222'::uuid),
             (3, '33333333-3333-4333-8333-333333333333'::uuid),
             (4, '44444444-4444-4444-8444-444444444444'::uuid)) as v(n, uid)
join public.usuarios u on u.id = v.uid;

insert into public.cartoes (id, usuario_id, nome, limite, dia_fechamento, dia_vencimento, visibilidade)
select ('cc000000-0000-4000-8000-00000000000' || n)::uuid, v.uid,
       'Cartao ' || n, 1000 * n, 10, 17, 'privado'
from (values (1, '11111111-1111-4111-8111-111111111111'::uuid),
             (2, '22222222-2222-4222-8222-222222222222'::uuid),
             (3, '33333333-3333-4333-8333-333333333333'::uuid),
             (4, '44444444-4444-4444-8444-444444444444'::uuid)) as v(n, uid);

insert into public.lancamentos (usuario_id, tipo, valor, classe, categoria_id, descricao, visibilidade)
select v.uid, 'gasto', 50 * v.n, 'variavel',
       (select c.id from public.categorias c where c.usuario_id = v.uid and c.nome = 'Lazer'),
       'gasto de teste', 'privado'
from (values (1, '11111111-1111-4111-8111-111111111111'::uuid),
             (2, '22222222-2222-4222-8222-222222222222'::uuid),
             (3, '33333333-3333-4333-8333-333333333333'::uuid),
             (4, '44444444-4444-4444-8444-444444444444'::uuid)) as v(n, uid);

-- Fotografia de parceiro_id ANTES da 0008, para provar que a migracao nao
-- mexeu no vinculo.
create table teste_backfill.parceiro_antes as
  select id, parceiro_id from public.usuarios;

-- Contagens de referencia das entidades preexistentes.
create table teste_backfill.contagem_antes as
  select 'contas' as tabela, count(*) from public.contas
  union all select 'cartoes', count(*) from public.cartoes
  union all select 'categorias', count(*) from public.categorias
  union all select 'lancamentos', count(*) from public.lancamentos;

do $$ begin raise notice 'setup pronto: A/B reciprocos, C unilateral, D isolado'; end $$;
