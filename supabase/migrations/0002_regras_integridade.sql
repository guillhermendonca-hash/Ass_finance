-- =====================================================================
-- 0002 — Helpers de parceria, integridade de vinculos e saldo de conta
-- =====================================================================

-- ---------------------------------------------------------- parceria
-- O vinculo so vale se for RECIPROCO: A aponta para B e B aponta para A.
-- Sem isso, qualquer usuario poderia colocar o id de um estranho em
-- parceiro_id e passar a enxergar os dados 'casal' dele.
create or replace function app.sao_parceiros(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.usuarios ua
    join public.usuarios ub on ub.id = ua.parceiro_id
    where ua.id = a
      and ub.id = b
      and ub.parceiro_id = ua.id
  );
$$;

-- Parceiro confirmado do usuario logado (null se nao houver reciprocidade).
create or replace function app.parceiro_atual()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select ub.id
  from public.usuarios ua
  join public.usuarios ub on ub.id = ua.parceiro_id
  where ua.id = auth.uid()
    and ub.parceiro_id = ua.id;
$$;

revoke all on function app.sao_parceiros(uuid, uuid) from public;
revoke all on function app.parceiro_atual() from public;
grant execute on function app.sao_parceiros(uuid, uuid) to authenticated;
grant execute on function app.parceiro_atual() to authenticated;

-- ------------------------------------------- integridade dos vinculos
-- Impede apontar um lancamento para conta/cartao/categoria de outra
-- pessoa. A excecao sao contas e cartoes marcados como 'casal', que o
-- parceiro confirmado tambem usa.
create or replace function app.valida_vinculos_lancamento()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.categoria_id is not null
     and not exists (
       select 1 from public.categorias c
       where c.id = new.categoria_id and c.usuario_id = new.usuario_id
     )
  then
    raise exception 'Categoria % nao pertence ao dono do lancamento', new.categoria_id
      using errcode = '23514';
  end if;

  if new.conta_id is not null
     and not exists (
       select 1 from public.contas c
       where c.id = new.conta_id
         and (c.usuario_id = new.usuario_id
              or (c.visibilidade = 'casal'
                  and app.sao_parceiros(c.usuario_id, new.usuario_id)))
     )
  then
    raise exception 'Conta % nao esta disponivel para o dono do lancamento', new.conta_id
      using errcode = '23514';
  end if;

  if new.cartao_id is not null
     and not exists (
       select 1 from public.cartoes c
       where c.id = new.cartao_id
         and (c.usuario_id = new.usuario_id
              or (c.visibilidade = 'casal'
                  and app.sao_parceiros(c.usuario_id, new.usuario_id)))
     )
  then
    raise exception 'Cartao % nao esta disponivel para o dono do lancamento', new.cartao_id
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists trg_valida_vinculos on public.lancamentos;
create trigger trg_valida_vinculos
  before insert or update on public.lancamentos
  for each row execute function app.valida_vinculos_lancamento();

-- ------------------------------------------------- saldo das contas
-- "Ao vincular a uma conta, o saldo da conta se ajusta" (secao 5.2).
-- SECURITY DEFINER porque o parceiro pode lancar em conta 'casal' que
-- nao e dele; o trigger acima ja garantiu que o vinculo e legitimo.
create or replace function app.delta_saldo(p_tipo public.tipo_lancamento, p_valor numeric)
returns numeric language sql immutable as $$
  select case when p_tipo = 'receita' then p_valor else -p_valor end;
$$;

create or replace function app.aplica_saldo_conta()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.conta_id is not null then
    update public.contas
       set saldo_atual = saldo_atual - app.delta_saldo(old.tipo, old.valor)
     where id = old.conta_id;
  end if;

  if tg_op in ('INSERT', 'UPDATE') and new.conta_id is not null then
    update public.contas
       set saldo_atual = saldo_atual + app.delta_saldo(new.tipo, new.valor)
     where id = new.conta_id;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end $$;

drop trigger if exists trg_aplica_saldo on public.lancamentos;
create trigger trg_aplica_saldo
  after insert or update or delete on public.lancamentos
  for each row execute function app.aplica_saldo_conta();
