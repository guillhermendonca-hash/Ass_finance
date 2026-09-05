-- =====================================================================
-- 0001 — Esquema base (Fase 1)
-- Tabelas: usuarios, contas, cartoes, categorias, lancamentos
-- =====================================================================

create extension if not exists "pgcrypto";

-- Schema interno: helpers que NAO devem virar endpoint REST.
-- O PostgREST so expoe os schemas configurados (public, graphql_public),
-- entao nada em "app" fica acessivel pelo cliente.
create schema if not exists app;
grant usage on schema app to authenticated;

-- ---------------------------------------------------------------- tipos
do $$ begin
  create type public.visibilidade as enum ('privado', 'total_compartilhado', 'casal');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.tipo_lancamento as enum ('receita', 'gasto');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.classe_lancamento as enum ('essencial', 'variavel', 'receita');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------ usuarios
create table if not exists public.usuarios (
  id                 uuid primary key references auth.users (id) on delete cascade,
  nome               text not null default '',
  email              text not null,
  renda_fixa_mensal  numeric(14, 2) not null default 0 check (renda_fixa_mensal >= 0),
  parceiro_id        uuid references public.usuarios (id) on delete set null,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  constraint parceiro_nao_e_o_proprio check (parceiro_id is null or parceiro_id <> id)
);

comment on column public.usuarios.parceiro_id is
  'Vinculo com o outro usuario. Cada lado aponta para o outro por conta propria: '
  'o vinculo so vale quando e reciproco (ver app.sao_parceiros).';

-- -------------------------------------------------------------- contas
create table if not exists public.contas (
  id             uuid primary key default gen_random_uuid(),
  usuario_id     uuid not null references public.usuarios (id) on delete cascade,
  nome           text not null check (length(trim(nome)) > 0),
  saldo_atual    numeric(14, 2) not null default 0,
  visibilidade   public.visibilidade not null default 'privado',
  arquivada      boolean not null default false,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- ------------------------------------------------------------- cartoes
create table if not exists public.cartoes (
  id              uuid primary key default gen_random_uuid(),
  usuario_id      uuid not null references public.usuarios (id) on delete cascade,
  nome            text not null check (length(trim(nome)) > 0),
  limite          numeric(14, 2) not null default 0 check (limite >= 0),
  dia_fechamento  smallint not null check (dia_fechamento between 1 and 31),
  dia_vencimento  smallint not null check (dia_vencimento between 1 and 31),
  visibilidade    public.visibilidade not null default 'privado',
  arquivado       boolean not null default false,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

-- ---------------------------------------------------------- categorias
create table if not exists public.categorias (
  id             uuid primary key default gen_random_uuid(),
  usuario_id     uuid not null references public.usuarios (id) on delete cascade,
  nome           text not null check (length(trim(nome)) > 0),
  classe_padrao  public.classe_lancamento not null default 'variavel',
  cor            text not null default '#7B1D2E' check (cor ~* '^#[0-9a-f]{6}$'),
  arquivada      boolean not null default false,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create unique index if not exists categorias_usuario_nome_uk
  on public.categorias (usuario_id, lower(trim(nome)));

-- --------------------------------------------------------- lancamentos
create table if not exists public.lancamentos (
  id             uuid primary key default gen_random_uuid(),
  usuario_id     uuid not null references public.usuarios (id) on delete cascade,
  tipo           public.tipo_lancamento not null,
  valor          numeric(14, 2) not null check (valor > 0),
  data           date not null default current_date,
  classe         public.classe_lancamento not null,
  categoria_id   uuid references public.categorias (id) on delete set null,
  descricao      text,
  conta_id       uuid references public.contas (id) on delete set null,
  cartao_id      uuid references public.cartoes (id) on delete set null,
  visibilidade   public.visibilidade not null default 'privado',
  recorrente     boolean not null default false,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),

  -- O valor e sempre positivo; quem da o sinal e o "tipo".
  constraint classe_coerente_com_tipo check (
    (tipo = 'receita' and classe = 'receita') or
    (tipo = 'gasto'   and classe in ('essencial', 'variavel'))
  ),
  -- Um lancamento sai da conta OU do cartao, nunca dos dois
  -- (dois vinculos contariam o mesmo gasto duas vezes).
  constraint origem_unica check (not (conta_id is not null and cartao_id is not null))
);

create index if not exists lancamentos_usuario_data_idx
  on public.lancamentos (usuario_id, data desc);
create index if not exists lancamentos_visibilidade_idx
  on public.lancamentos (usuario_id, visibilidade);
create index if not exists lancamentos_categoria_idx on public.lancamentos (categoria_id);
create index if not exists lancamentos_conta_idx     on public.lancamentos (conta_id);
create index if not exists lancamentos_cartao_idx    on public.lancamentos (cartao_id);
create index if not exists contas_usuario_idx        on public.contas (usuario_id);
create index if not exists cartoes_usuario_idx       on public.cartoes (usuario_id);
create index if not exists categorias_usuario_idx    on public.categorias (usuario_id);
create index if not exists usuarios_parceiro_idx     on public.usuarios (parceiro_id);

-- ------------------------------------------------------ atualizado_em
create or replace function app.toca_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['usuarios', 'contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format('drop trigger if exists trg_atualizado_em on public.%I', t);
    execute format(
      'create trigger trg_atualizado_em before update on public.%I
         for each row execute function app.toca_atualizado_em()', t);
  end loop;
end $$;
