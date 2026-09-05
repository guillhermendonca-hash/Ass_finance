-- =====================================================================
-- 0004 — API de privacidade: "somar sem vazar o item"
--
-- A esfera 'total_compartilhado' fecha a linha para o parceiro no RLS.
-- O que ele recebe sai daqui: SECURITY DEFINER que so devolve SOMA por
-- classe/categoria. Nao ha caminho nesta API que retorne descricao,
-- data ou valor de um lancamento individual do parceiro.
-- =====================================================================

-- --------------------------------------------------- vinculo de casal
-- Cada lado declara o seu proprio parceiro. O vinculo so passa a valer
-- quando os dois se apontam (app.sao_parceiros), o que faz do consenso
-- um requisito e nao uma formalidade.
create or replace function public.meu_parceiro()
returns table (id uuid, nome text, vinculo_confirmado boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_alvo uuid;
begin
  select u.parceiro_id into v_alvo from public.usuarios u where u.id = auth.uid();
  if v_alvo is null then
    return;
  end if;

  return query
    select p.id,
           p.nome,
           (p.parceiro_id = auth.uid()) as vinculo_confirmado
    from public.usuarios p
    where p.id = v_alvo;
end $$;

create or replace function public.vincular_parceiro(p_email text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_alvo uuid;
  v_parceiro_do_alvo uuid;
begin
  select u.id, u.parceiro_id into v_alvo, v_parceiro_do_alvo
  from public.usuarios u
  where lower(u.email) = lower(trim(p_email));

  if v_alvo is null then
    raise exception 'Nao existe usuario com esse e-mail' using errcode = 'P0002';
  end if;
  if v_alvo = auth.uid() then
    raise exception 'Voce nao pode se vincular a si mesmo' using errcode = '22023';
  end if;
  if v_parceiro_do_alvo is not null and v_parceiro_do_alvo <> auth.uid() then
    raise exception 'Esse usuario ja esta vinculado a outra pessoa' using errcode = '22023';
  end if;

  update public.usuarios set parceiro_id = v_alvo where id = auth.uid();
  return v_alvo;
end $$;

create or replace function public.desvincular_parceiro()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.usuarios set parceiro_id = null where id = auth.uid();
$$;

-- ------------------------------------------ agregado do parceiro
-- Devolve somas do periodo. 'quantidade' vai junto de proposito: com
-- um unico lancamento na categoria, a soma E o item — cabe a interface
-- avisar, e ao dono decidir se compartilha aquela categoria.
create or replace function public.resumo_do_parceiro(
  p_inicio date default date_trunc('month', current_date)::date,
  p_fim    date default (date_trunc('month', current_date) + interval '1 month - 1 day')::date
)
returns table (
  escopo          public.visibilidade,
  tipo            public.tipo_lancamento,
  classe          public.classe_lancamento,
  categoria_nome  text,
  categoria_cor   text,
  total           numeric,
  quantidade      bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select l.visibilidade      as escopo,
         l.tipo,
         l.classe,
         coalesce(c.nome, 'Sem categoria') as categoria_nome,
         coalesce(c.cor, '#8A7F79')        as categoria_cor,
         sum(l.valor)                      as total,
         count(*)                          as quantidade
  from public.lancamentos l
  left join public.categorias c on c.id = l.categoria_id
  where l.usuario_id = app.parceiro_atual()
    and l.visibilidade in ('total_compartilhado', 'casal')
    and l.data between p_inicio and p_fim
  group by l.visibilidade, l.tipo, l.classe, c.nome, c.cor
  order by 6 desc;
$$;

-- Contas e cartoes 'total_compartilhado' viram um numero unico; os do
-- casal o parceiro ja le em detalhe pelo RLS e nao entram aqui.
create or replace function public.saldos_agregados_do_parceiro()
returns table (saldo_em_contas numeric, contas_consideradas bigint, limite_em_cartoes numeric)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
           select sum(saldo_atual) from public.contas
           where usuario_id = app.parceiro_atual()
             and visibilidade = 'total_compartilhado' and not arquivada
         ), 0),
         coalesce((
           select count(*) from public.contas
           where usuario_id = app.parceiro_atual()
             and visibilidade = 'total_compartilhado' and not arquivada
         ), 0),
         coalesce((
           select sum(limite) from public.cartoes
           where usuario_id = app.parceiro_atual()
             and visibilidade = 'total_compartilhado' and not arquivado
         ), 0);
$$;

revoke all on function public.meu_parceiro() from public;
revoke all on function public.vincular_parceiro(text) from public;
revoke all on function public.desvincular_parceiro() from public;
revoke all on function public.resumo_do_parceiro(date, date) from public;
revoke all on function public.saldos_agregados_do_parceiro() from public;

grant execute on function public.meu_parceiro() to authenticated;
grant execute on function public.vincular_parceiro(text) to authenticated;
grant execute on function public.desvincular_parceiro() to authenticated;
grant execute on function public.resumo_do_parceiro(date, date) to authenticated;
grant execute on function public.saldos_agregados_do_parceiro() to authenticated;
