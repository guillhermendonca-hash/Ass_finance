-- =====================================================================
-- 0005 — Provisionamento do novo usuario
-- Cria a linha em public.usuarios e semeia as categorias iniciais.
-- "Vem com um conjunto inicial, mas o usuario cria as proprias" (secao 4).
-- =====================================================================

create or replace function app.provisiona_usuario()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.usuarios (id, email, nome)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.provisiona_usuario();
