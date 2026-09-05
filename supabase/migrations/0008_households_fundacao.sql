-- =====================================================================
-- 0008 — Fundacao transicional de households (SHADOW)
--
-- Esta migracao adiciona a estrutura de grupo familiar e a preenche a
-- partir do estado atual de usuarios.parceiro_id. Nesta fatia ela e
-- SOMENTE SOMBRA:
--
--   * parceiro_id continua sendo a autoridade;
--   * app.sao_parceiros e app.parceiro_atual seguem intactos;
--   * as policies, os grants e as RPCs de 0003/0004/0006/0007 seguem
--     intactos;
--   * o cliente nao le nem escreve nas tabelas novas.
--
-- ATENCAO — NAO IMPLANTAR SOZINHA. O backfill fotografa o estado de
-- parceiro_id no momento em que a migracao roda. Vinculos criados ou
-- desfeitos DEPOIS disso nao sao refletidos aqui: a sombra diverge. A
-- TAR-002B2 reconcilia o estado corrente e faz o cutover. Nao pode haver
-- deploy entre B1 e B2.
-- =====================================================================

-- ------------------------------------------------------------ tabelas
create table if not exists public.households (
  id          uuid primary key default gen_random_uuid(),
  -- ON DELETE SET NULL de proposito: apagar quem criou o grupo nao pode
  -- levar junto o household do outro membro.
  criado_por  uuid references public.usuarios (id) on delete set null,
  criado_em   timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id  uuid not null references public.households (id) on delete cascade,
  usuario_id    uuid not null references public.usuarios (id) on delete cascade,
  posicao       smallint not null check (posicao in (1, 2)),
  criado_em     timestamptz not null default now(),

  -- impede o mesmo membro duas vezes no mesmo grupo
  constraint household_members_pk primary key (household_id, usuario_id),

  -- um usuario tem exatamente uma membresia ativa
  constraint household_members_usuario_uk unique (usuario_id),

  -- o teto de dois membros sai daqui: 'posicao' so aceita 1 ou 2, e cada
  -- posicao e unica no grupo. E indice unico, entao segura concorrencia —
  -- ao contrario de um gatilho com count(*), que duas transacoes
  -- simultaneas furam.
  constraint household_members_posicao_uk unique (household_id, posicao)
);

create index if not exists household_members_household_idx
  on public.household_members (household_id);

-- ---------------------------------------------------------- privacidade
-- O cliente nao alcanca a sombra nesta fatia: RLS ligada e sem policy
-- nenhuma, mais revogacao de todo privilegio. Cinto e suspensorio.
alter table public.households        enable row level security;
alter table public.household_members enable row level security;

revoke all on public.households        from public, anon, authenticated;
revoke all on public.household_members from public, anon, authenticated;

-- --------------------------------------------------------- helper interno
create or replace function app.household_de(p_usuario uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select hm.household_id
  from public.household_members hm
  where hm.usuario_id = p_usuario;
$$;

revoke all on function app.household_de(uuid) from public, anon, authenticated;

-- ------------------------------------------------- coluna nas entidades
alter table public.contas      add column if not exists household_id uuid references public.households (id);
alter table public.cartoes     add column if not exists household_id uuid references public.households (id);
alter table public.categorias  add column if not exists household_id uuid references public.households (id);
alter table public.lancamentos add column if not exists household_id uuid references public.households (id);

-- =====================================================================
-- BACKFILL
--
-- Agrupamento deterministico quanto aos membros:
--   * A e B com parceiro_id reciproco  -> um household, posicoes 1 e 2
--     ordenadas por id (o menor fica com a posicao 1);
--   * apontamento unilateral            -> household individual;
--   * sem parceiro                      -> household individual.
--
-- Os UUIDs sao gerados uma vez por grupo canonico, materializados em
-- tabela temporaria. Gerar dentro de subconsulta seria erro: gen_random_uuid()
-- e volatil e o planejador poderia reavalia-la por linha de saida,
-- separando o par.
-- =====================================================================
do $$
declare
  v_falta bigint;
begin
  create temporary table _pares_household (
    menor        uuid not null,
    maior        uuid not null,
    household_id uuid not null
  );

  insert into _pares_household (menor, maior, household_id)
  select least(a.id, b.id), greatest(a.id, b.id), gen_random_uuid()
  from public.usuarios a
  join public.usuarios b
    on b.id = a.parceiro_id
   and a.id = b.parceiro_id
  where a.id < b.id;

  create temporary table _individuais_household (
    usuario_id   uuid not null,
    household_id uuid not null
  );

  insert into _individuais_household (usuario_id, household_id)
  select u.id, gen_random_uuid()
  from public.usuarios u
  where not exists (
    select 1 from _pares_household p where u.id in (p.menor, p.maior)
  );

  insert into public.households (id, criado_por)
  select household_id, menor from _pares_household
  union all
  select household_id, usuario_id from _individuais_household;

  insert into public.household_members (household_id, usuario_id, posicao)
  select household_id, menor, 1 from _pares_household
  union all
  select household_id, maior, 2 from _pares_household
  union all
  select household_id, usuario_id, 1 from _individuais_household;

  -- todo usuario com exatamente uma membresia
  select count(*) into v_falta
  from public.usuarios u
  where not exists (select 1 from public.household_members hm where hm.usuario_id = u.id);
  if v_falta > 0 then
    raise exception 'backfill: % usuario(s) ficaram sem membresia', v_falta;
  end if;

  select count(*) into v_falta
  from (select usuario_id from public.household_members group by usuario_id having count(*) > 1) d;
  if v_falta > 0 then
    raise exception 'backfill: % usuario(s) com membresia duplicada', v_falta;
  end if;

  drop table _pares_household;
  drop table _individuais_household;
end $$;

-- O carimbo de atualizado_em fica suspenso durante o backfill: preencher
-- uma coluna nova nao e edicao do usuario e nao pode reescrever a data de
-- alteracao de todas as linhas existentes.
alter table public.contas      disable trigger trg_atualizado_em;
alter table public.cartoes     disable trigger trg_atualizado_em;
alter table public.categorias  disable trigger trg_atualizado_em;
alter table public.lancamentos disable trigger trg_atualizado_em;

update public.contas      e set household_id = hm.household_id from public.household_members hm where hm.usuario_id = e.usuario_id;
update public.cartoes     e set household_id = hm.household_id from public.household_members hm where hm.usuario_id = e.usuario_id;
update public.categorias  e set household_id = hm.household_id from public.household_members hm where hm.usuario_id = e.usuario_id;
update public.lancamentos e set household_id = hm.household_id from public.household_members hm where hm.usuario_id = e.usuario_id;

alter table public.contas      enable trigger trg_atualizado_em;
alter table public.cartoes     enable trigger trg_atualizado_em;
alter table public.categorias  enable trigger trg_atualizado_em;
alter table public.lancamentos enable trigger trg_atualizado_em;

do $$
declare
  t text;
  v_falta bigint;
begin
  foreach t in array array['contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format('select count(*) from public.%I where household_id is null', t) into v_falta;
    if v_falta > 0 then
      raise exception 'backfill: % linha(s) de %I sem household', v_falta, t;
    end if;
  end loop;
end $$;

alter table public.contas      alter column household_id set not null;
alter table public.cartoes     alter column household_id set not null;
alter table public.categorias  alter column household_id set not null;
alter table public.lancamentos alter column household_id set not null;

create index if not exists contas_household_idx      on public.contas (household_id);
create index if not exists cartoes_household_idx     on public.cartoes (household_id);
create index if not exists categorias_household_idx  on public.categorias (household_id);
create index if not exists lancamentos_household_idx on public.lancamentos (household_id);

-- ---------------------------------------------------------- derivacao
-- household_id nunca vem do cliente: e sempre derivado do usuario_id da
-- linha. Payload omitido recebe o valor certo; payload forjado e
-- sobrescrito. E falha fechado se o dono nao tiver membresia.
--
-- household_id tambem nao entra nos grants de UPDATE da 0006, entao o
-- cliente nem consegue nomea-la numa alteracao.
create or replace function app.deriva_household()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household uuid;
begin
  select hm.household_id into v_household
  from public.household_members hm
  where hm.usuario_id = new.usuario_id;

  if v_household is null then
    raise exception 'usuario % nao possui membresia ativa em household', new.usuario_id
      using errcode = '23502';
  end if;

  new.household_id := v_household;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format('drop trigger if exists trg_deriva_household on public.%I', t);
    execute format(
      'create trigger trg_deriva_household before insert or update on public.%I
         for each row execute function app.deriva_household()', t);
  end loop;
end $$;

-- ------------------------------------------------- provisionamento novo
-- Mesma assinatura e mesmo gatilho de 0005. A ordem importa: o household e
-- a membresia precisam existir antes das categorias, senao a derivacao
-- nao encontra o grupo e falha fechado.
create or replace function app.provisiona_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household uuid;
begin
  insert into public.usuarios (id, email, nome)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

  select hm.household_id into v_household
  from public.household_members hm
  where hm.usuario_id = new.id;

  if v_household is null then
    insert into public.households (criado_por) values (new.id)
    returning id into v_household;

    insert into public.household_members (household_id, usuario_id, posicao)
    values (v_household, new.id, 1);
  end if;

  insert into public.categorias (usuario_id, nome, classe_padrao, cor)
  values
    (new.id, 'Moradia',       'essencial', '#7B1D2E'),
    (new.id, 'Alimentação',   'essencial', '#9A3D4C'),
    (new.id, 'Transporte',    'essencial', '#8A5A2B'),
    (new.id, 'Saúde',         'essencial', '#2F6B4F'),
    (new.id, 'Contas fixas',  'essencial', '#5C4033'),
    (new.id, 'Educação',      'essencial', '#4A5D6B'),
    (new.id, 'Lazer',         'variavel',  '#B5741A'),
    (new.id, 'Restaurante',   'variavel',  '#C87A2E'),
    (new.id, 'Compras',       'variavel',  '#A8823C'),
    (new.id, 'Assinaturas',   'variavel',  '#8C6B4F'),
    (new.id, 'Outros',        'variavel',  '#8A7F79'),
    (new.id, 'Salário',       'receita',   '#2F6B4F'),
    (new.id, 'Renda extra',   'receita',   '#3E7D5E')
  on conflict do nothing;

  return new;
end $$;
