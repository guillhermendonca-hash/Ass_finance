-- =====================================================================
-- Emula o mínimo do Supabase (schema auth, roles e auth.uid()) para dar
-- para rodar as migrações e o teste de RLS num Postgres local, sem
-- precisar de um projeto na nuvem.
--
-- Só para teste. Não vai para o banco de produção.
-- =====================================================================

do $$ begin create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin;  exception when duplicate_object then null; end $$;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  instance_id        uuid,
  id                 uuid primary key,
  aud                text,
  role               text,
  email              text unique,
  encrypted_password text,
  email_confirmed_at timestamptz,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now(),
  raw_app_meta_data  jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb
);

-- Mesma definição que o Supabase usa: lê o "sub" do JWT da requisição.
create or replace function auth.uid()
returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

create or replace function auth.role()
returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
$$;

grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
