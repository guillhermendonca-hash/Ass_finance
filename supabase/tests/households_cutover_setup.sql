-- =====================================================================
-- Divergencia deliberada entre a fotografia da B1 e o estado corrente,
-- aplicada DEPOIS do backfill e ANTES da 0009.
--
-- Estado que chega aqui (vindo do arnes B1):
--   A e B  -> mesmo household (par reciproco)
--   C      -> individual (apontava para A, sem volta)
--   D      -> individual (sem parceiro)
--   E      -> individual (criado depois da 0008)
--
-- O que fazemos:
--   * quebramos a reciprocidade de A/B: A deixa de apontar, B continua
--     apontando para A. Um par que ESTA junto precisa ser separado, e
--     sobra um ponteiro unilateral obsoleto que nao pode dar acesso.
--   * tornamos C e D reciprocos: dois que estao SEPARADOS precisam ser
--     unidos.
--   * E fica como esta, para provar que o isolado nao se mexe.
--
-- Como o cutover reconstroi tudo do estado corrente, isso exercita as
-- duas direcoes ao mesmo tempo.
-- =====================================================================

create schema if not exists teste_cutover;

-- A para de apontar para B; B mantem o ponteiro obsoleto.
update public.usuarios set parceiro_id = null
 where id = '11111111-1111-4111-8111-111111111111';

-- C e D passam a se apontar.
update public.usuarios set parceiro_id = '44444444-4444-4444-8444-444444444444'
 where id = '33333333-3333-4333-8333-333333333333';
update public.usuarios set parceiro_id = '33333333-3333-4333-8333-333333333333'
 where id = '44444444-4444-4444-8444-444444444444';

-- --------------------------------------------------- fotografias
create table teste_cutover.parceiro_antes as
  select id, parceiro_id from public.usuarios;

create table teste_cutover.household_antes as
  select usuario_id, household_id, posicao from public.household_members;

create table teste_cutover.households_antes as
  select id from public.households;

-- donos e carimbos, linha a linha, das quatro tabelas
create table teste_cutover.entidades_antes as
  select 'contas'::text as tabela, id, usuario_id, atualizado_em from public.contas
  union all select 'cartoes', id, usuario_id, atualizado_em from public.cartoes
  union all select 'categorias', id, usuario_id, atualizado_em from public.categorias
  union all select 'lancamentos', id, usuario_id, atualizado_em from public.lancamentos;

create table teste_cutover.contagem_antes as
  select 'contas'::text as tabela, count(*) from public.contas
  union all select 'cartoes', count(*) from public.cartoes
  union all select 'categorias', count(*) from public.categorias
  union all select 'lancamentos', count(*) from public.lancamentos
  union all select 'usuarios', count(*) from public.usuarios;

do $$
begin
  raise notice 'divergencia armada: A/B deixaram de ser reciprocos, C/D passaram a ser';
end $$;
