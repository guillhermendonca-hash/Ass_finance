-- =====================================================================
-- 0009 — Cutover: household passa a ser a autoridade de acesso
--
-- Ate aqui parceiro_id decidia quem via o que. A partir desta migracao
-- quem decide e a MEMBRESIA no household. parceiro_id sobrevive apenas
-- como estado de solicitacao/compatibilidade para o frontend atual, e
-- nunca mais como condicao de autorizacao.
--
-- Ordem: travar -> reconciliar a sombra com o estado corrente ->
-- trocar helpers -> recriar policies -> trocar agregados -> trocar RPCs.
--
-- Sem BEGIN/COMMIT embutido: a fronteira transacional e a do arquivo
-- (psql -1 nos arneses, batch do Supabase CLI em deploy).
-- =====================================================================

-- ---------------------------------------------------------------- locks
-- EXCLUSIVE bloqueia toda escrita concorrente (INSERT/UPDATE/DELETE
-- pegam ROW EXCLUSIVE, que conflita) e ainda deixa SELECT passar. A
-- ordem da lista e a ordem de aquisicao, fixa, para nao criar deadlock
-- com as RPCs — que travam usuarios primeiro, tambem em ordem estavel.
lock table public.usuarios,
           public.households,
           public.household_members,
           public.contas,
           public.cartoes,
           public.categorias,
           public.lancamentos
  in exclusive mode;

-- =====================================================================
-- 1. RECONCILIACAO
--
-- A B1 fotografou parceiro_id no momento em que rodou. De la para ca o
-- vinculo pode ter mudado. Aqui reconstruimos o agrupamento desejado a
-- partir do estado CORRENTE e movemos a sombra para ele.
--
-- Como a B1 nunca foi implantada sozinha, os ids de household podem ser
-- substituidos: geramos um household novo por grupo canonico, movemos
-- membresias e entidades, validamos, e so entao removemos os antigos que
-- ficaram orfaos.
-- =====================================================================
do $$
declare
  v_falta bigint;
  t text;
begin
  create temporary table _grupo_desejado (
    chave        text primary key,
    household_id uuid not null
  );

  create temporary table _mapa_desejado (
    usuario_id   uuid primary key,
    household_id uuid not null,
    posicao      smallint not null
  );

  -- Pares reciprocos pelo estado CORRENTE. A chave canonica e o par
  -- ordenado de uuids, entao o agrupamento nao depende de ordem de linha.
  insert into _grupo_desejado (chave, household_id)
  select least(a.id, b.id)::text || '|' || greatest(a.id, b.id)::text,
         gen_random_uuid()
  from public.usuarios a
  join public.usuarios b
    on b.id = a.parceiro_id
   and a.id = b.parceiro_id
  where a.id < b.id;

  insert into _mapa_desejado (usuario_id, household_id, posicao)
  select u.id,
         g.household_id,
         case when u.id::text = split_part(g.chave, '|', 1) then 1 else 2 end
  from _grupo_desejado g
  join public.usuarios u
    on u.id::text in (split_part(g.chave, '|', 1), split_part(g.chave, '|', 2));

  -- Unilateral ou sem parceiro: individual, posicao 1.
  insert into _grupo_desejado (chave, household_id)
  select u.id::text, gen_random_uuid()
  from public.usuarios u
  where not exists (select 1 from _mapa_desejado m where m.usuario_id = u.id);

  insert into _mapa_desejado (usuario_id, household_id, posicao)
  select u.id, g.household_id, 1
  from public.usuarios u
  join _grupo_desejado g on g.chave = u.id::text
  where not exists (select 1 from _mapa_desejado m where m.usuario_id = u.id);

  -- Invariantes do mapa, antes de tocar em qualquer linha real
  select count(*) into v_falta
  from public.usuarios u
  where not exists (select 1 from _mapa_desejado m where m.usuario_id = u.id);
  if v_falta > 0 then
    raise exception 'reconciliacao: % usuario(s) sem mapeamento', v_falta;
  end if;

  select count(*) into v_falta
  from (select household_id from _mapa_desejado group by household_id having count(*) > 2) x;
  if v_falta > 0 then
    raise exception 'reconciliacao: % household(s) com mais de dois membros', v_falta;
  end if;

  select count(*) into v_falta
  from (select household_id, posicao from _mapa_desejado
        group by household_id, posicao having count(*) > 1) x;
  if v_falta > 0 then
    raise exception 'reconciliacao: posicao duplicada dentro de um household';
  end if;

  -- criado_por = o membro da posicao 1, que e unico por household e
  -- deterministico. (min() nao existe para uuid no Postgres.)
  insert into public.households (id, criado_por)
  select m.household_id, m.usuario_id
  from _mapa_desejado m
  where m.posicao = 1;

  -- Membresias primeiro: o gatilho de derivacao le daqui quando as
  -- entidades forem movidas logo abaixo.
  update public.household_members hm
     set household_id = m.household_id,
         posicao      = m.posicao
  from _mapa_desejado m
  where m.usuario_id = hm.usuario_id;

  -- Troca estrutural: nao e edicao do usuario, entao o carimbo de
  -- atualizado_em nao pode andar. Desabilitar aqui e seguro porque a
  -- transacao ja detem EXCLUSIVE nas quatro tabelas — nenhuma outra
  -- sessao chega a ver o gatilho desligado, e um erro reverte tudo.
  alter table public.contas      disable trigger trg_atualizado_em;
  alter table public.cartoes     disable trigger trg_atualizado_em;
  alter table public.categorias  disable trigger trg_atualizado_em;
  alter table public.lancamentos disable trigger trg_atualizado_em;

  update public.contas      e set household_id = m.household_id from _mapa_desejado m where m.usuario_id = e.usuario_id;
  update public.cartoes     e set household_id = m.household_id from _mapa_desejado m where m.usuario_id = e.usuario_id;
  update public.categorias  e set household_id = m.household_id from _mapa_desejado m where m.usuario_id = e.usuario_id;
  update public.lancamentos e set household_id = m.household_id from _mapa_desejado m where m.usuario_id = e.usuario_id;

  alter table public.contas      enable trigger trg_atualizado_em;
  alter table public.cartoes     enable trigger trg_atualizado_em;
  alter table public.categorias  enable trigger trg_atualizado_em;
  alter table public.lancamentos enable trigger trg_atualizado_em;

  -- Households antigos que ficaram sem ninguem e sem nada
  delete from public.households h
  where not exists (select 1 from public.household_members hm where hm.household_id = h.id)
    and not exists (select 1 from public.contas      x where x.household_id = h.id)
    and not exists (select 1 from public.cartoes     x where x.household_id = h.id)
    and not exists (select 1 from public.categorias  x where x.household_id = h.id)
    and not exists (select 1 from public.lancamentos x where x.household_id = h.id);

  -- Validacao final
  select count(*) into v_falta
  from public.household_members hm
  join _mapa_desejado m on m.usuario_id = hm.usuario_id
  where hm.household_id is distinct from m.household_id or hm.posicao is distinct from m.posicao;
  if v_falta > 0 then
    raise exception 'reconciliacao: % membresia(s) fora do mapa', v_falta;
  end if;

  foreach t in array array['contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format(
      'select count(*) from public.%I e
         join public.household_members hm on hm.usuario_id = e.usuario_id
        where e.household_id is distinct from hm.household_id', t) into v_falta;
    if v_falta > 0 then
      raise exception 'reconciliacao: % linha(s) de % com household divergente', v_falta, t;
    end if;
  end loop;

  select count(*) into v_falta
  from public.households h
  where not exists (select 1 from _mapa_desejado m where m.household_id = h.id);
  if v_falta > 0 then
    raise exception 'reconciliacao: % household(s) antigo(s) ainda presente(s)', v_falta;
  end if;

  drop table _grupo_desejado;
  drop table _mapa_desejado;
end $$;

-- =====================================================================
-- 2. HELPERS — a autoridade passa a ser a membresia
-- =====================================================================

-- Verdadeiro so para dois usuarios DISTINTOS no mesmo household. Como o
-- household tem no maximo dois membros (indice unico em posicao), isso
-- equivale a "sao o casal ativo". Nao consulta parceiro_id.
create or replace function app.sao_parceiros(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members ma
    join public.household_members mb on mb.household_id = ma.household_id
    where ma.usuario_id = a
      and mb.usuario_id = b
      and a <> b
  );
$$;

-- O outro membro do household de quem esta logado. Null em household
-- individual. Nao consulta parceiro_id.
create or replace function app.parceiro_atual()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select mb.usuario_id
  from public.household_members ma
  join public.household_members mb
    on mb.household_id = ma.household_id
   and mb.usuario_id <> ma.usuario_id
  where ma.usuario_id = auth.uid();
$$;

-- Categoria continua pessoal. Conta e cartao de terceiro so entram
-- quando a entidade e 'casal' E os dois dividem household.
create or replace function app.valida_vinculos_lancamento()
returns trigger
language plpgsql
security definer
set search_path = ''
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

revoke all on function app.sao_parceiros(uuid, uuid) from public, anon;
revoke all on function app.parceiro_atual() from public, anon;
grant execute on function app.sao_parceiros(uuid, uuid) to authenticated;
grant execute on function app.parceiro_atual() to authenticated;

-- =====================================================================
-- 3. POLICIES — recriadas sobre a nova autoridade
--
-- As expressoes continuam as mesmas de 0003, e isso e proposital: o
-- comportamento funcional nao muda. O que mudou foi o SIGNIFICADO de
-- app.sao_parceiros, que agora le membresia. Nenhuma expressao aqui
-- menciona parceiro_id — nem antes, nem agora.
-- =====================================================================
drop policy if exists contas_select on public.contas;
create policy contas_select on public.contas
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists contas_update on public.contas;
create policy contas_update on public.contas
  for update to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  )
  with check (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists cartoes_select on public.cartoes;
create policy cartoes_select on public.cartoes
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists cartoes_update on public.cartoes;
create policy cartoes_update on public.cartoes
  for update to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  )
  with check (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists lancamentos_select on public.lancamentos;
create policy lancamentos_select on public.lancamentos
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists lancamentos_update on public.lancamentos;
create policy lancamentos_update on public.lancamentos
  for update to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  )
  with check (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists lancamentos_delete on public.lancamentos;
create policy lancamentos_delete on public.lancamentos
  for delete to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

-- INSERT, DELETE de contas/cartoes e a policy de categorias ficam como
-- estao: nao ha ampliacao de acesso nesta fatia.

-- =====================================================================
-- 4. AGREGADOS — mesma assinatura, mesmo formato, nova autoridade
--
-- Continuam achando o outro membro por app.parceiro_atual(), que agora
-- le membresia. A esfera privada segue invisivel e a granularidade nao
-- muda: soma por classe e categoria, nunca a linha.
-- =====================================================================
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
set search_path = ''
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

create or replace function public.saldos_agregados_do_parceiro()
returns table (saldo_em_contas numeric, contas_consideradas bigint, limite_em_cartoes numeric)
language sql
stable
security definer
set search_path = ''
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

-- =====================================================================
-- 5. RPCs DE VINCULO — assinaturas preservadas
--
-- parceiro_id vira apenas o registro da SOLICITACAO. Quem concede acesso
-- e a membresia, movida atomicamente aqui dentro.
-- =====================================================================

-- Mostra a solicitacao corrente, mas 'vinculo_confirmado' vem da
-- membresia — nunca da reciprocidade do ponteiro.
create or replace function public.meu_parceiro()
returns table (id uuid, nome text, vinculo_confirmado boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ator       uuid := auth.uid();
  v_confirmado uuid;
  v_solicitado uuid;
begin
  if v_ator is null then
    return;
  end if;

  v_confirmado := app.parceiro_atual();
  if v_confirmado is not null then
    return query
      select u.id, u.nome, true from public.usuarios u where u.id = v_confirmado;
    return;
  end if;

  select u.parceiro_id into v_solicitado from public.usuarios u where u.id = v_ator;
  if v_solicitado is null then
    return;
  end if;

  return query
    select u.id, u.nome, false from public.usuarios u where u.id = v_solicitado;
end $$;

create or replace function public.vincular_parceiro(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ator     uuid := auth.uid();
  v_alvo     uuid;
  v_menor    uuid;
  v_maior    uuid;
  v_ptr_ator uuid;
  v_ptr_alvo uuid;
  v_h_ator   uuid;
  v_h_alvo   uuid;
  n_ator     bigint;
  n_alvo     bigint;
  v_fica     uuid;
  v_sai      uuid;
  v_muda     uuid;
  v_pos      smallint;
begin
  if v_ator is null then
    raise exception 'sessao sem usuario autenticado' using errcode = '28000';
  end if;

  select u.id into v_alvo
  from public.usuarios u
  where lower(u.email) = lower(trim(p_email));

  if v_alvo is null then
    raise exception 'Nao existe usuario com esse e-mail' using errcode = 'P0002';
  end if;
  if v_alvo = v_ator then
    raise exception 'Voce nao pode se vincular a si mesmo' using errcode = '22023';
  end if;

  -- Trava as duas linhas SEMPRE na mesma ordem (menor uuid primeiro).
  -- Duas chamadas simultaneas e cruzadas se enfileiram em vez de travar
  -- uma na outra.
  v_menor := least(v_ator, v_alvo);
  v_maior := greatest(v_ator, v_alvo);
  perform 1 from public.usuarios where id = v_menor for update;
  perform 1 from public.usuarios where id = v_maior for update;

  -- Revalida DEPOIS do lock: o estado pode ter mudado enquanto esperavamos.
  select u.parceiro_id into v_ptr_ator from public.usuarios u where u.id = v_ator;
  select u.parceiro_id into v_ptr_alvo from public.usuarios u where u.id = v_alvo;

  if v_ptr_ator is not null and v_ptr_ator <> v_alvo then
    raise exception 'Voce ja declarou vinculo com outra pessoa' using errcode = '22023';
  end if;
  if v_ptr_alvo is not null and v_ptr_alvo <> v_ator then
    raise exception 'Esse usuario ja esta vinculado a outra pessoa' using errcode = '22023';
  end if;

  select hm.household_id into v_h_ator from public.household_members hm where hm.usuario_id = v_ator;
  select hm.household_id into v_h_alvo from public.household_members hm where hm.usuario_id = v_alvo;
  if v_h_ator is null or v_h_alvo is null then
    raise exception 'membresia ausente para ator ou alvo' using errcode = '23502';
  end if;

  -- Ator ou alvo ja dividindo household com um terceiro: nao ha o que fundir.
  select count(*) into n_ator from public.household_members where household_id = v_h_ator;
  select count(*) into n_alvo from public.household_members where household_id = v_h_alvo;

  if v_h_ator = v_h_alvo then
    -- Ja sao o casal ativo: idempotente, so registra a solicitacao.
    update public.usuarios set parceiro_id = v_alvo
     where id = v_ator and parceiro_id is distinct from v_alvo;
    return v_alvo;
  end if;

  if n_ator <> 1 then
    raise exception 'Voce ja divide um household com outra pessoa' using errcode = '22023';
  end if;
  if n_alvo <> 1 then
    raise exception 'Esse usuario ja divide um household com outra pessoa' using errcode = '22023';
  end if;

  -- PRIMEIRA DECLARACAO: grava o apontamento e para por aqui. Nao ha
  -- merge e nenhum dado passa a ser compartilhado.
  update public.usuarios set parceiro_id = v_alvo where id = v_ator;

  if v_ptr_alvo is distinct from v_ator then
    return v_alvo;
  end if;

  -- CONFIRMACAO: o alvo ja apontava de volta. Funde os dois individuais.
  -- Sobrevivente estavel: o household do menor uuid.
  if v_menor = v_ator then
    v_fica := v_h_ator; v_sai := v_h_alvo; v_muda := v_alvo;
  else
    v_fica := v_h_alvo; v_sai := v_h_ator; v_muda := v_ator;
  end if;

  select case
           when exists (select 1 from public.household_members
                         where household_id = v_fica and posicao = 1)
           then 2 else 1
         end
    into v_pos;

  update public.household_members
     set household_id = v_fica, posicao = v_pos
   where usuario_id = v_muda;

  -- As entidades acompanham o dono. O gatilho de derivacao recalcula a
  -- partir da membresia recem-movida e chega ao mesmo valor.
  update public.contas      set household_id = v_fica where usuario_id = v_muda;
  update public.cartoes     set household_id = v_fica where usuario_id = v_muda;
  update public.categorias  set household_id = v_fica where usuario_id = v_muda;
  update public.lancamentos set household_id = v_fica where usuario_id = v_muda;

  delete from public.households where id = v_sai;

  -- Invariantes: qualquer desvio derruba a transacao inteira.
  if (select count(*) from public.household_members where household_id = v_fica) <> 2 then
    raise exception 'merge invalido: household resultante nao ficou com dois membros'
      using errcode = '23514';
  end if;
  if not app.sao_parceiros(v_ator, v_alvo) then
    raise exception 'merge invalido: os dois nao ficaram no mesmo household'
      using errcode = '23514';
  end if;

  return v_alvo;
end $$;

create or replace function public.desvincular_parceiro()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ator  uuid := auth.uid();
  v_outro uuid;
  v_h     uuid;
  v_novo  uuid;
  v_menor uuid;
  v_maior uuid;
begin
  if v_ator is null then
    raise exception 'sessao sem usuario autenticado' using errcode = '28000';
  end if;

  select hm.household_id into v_h from public.household_members hm where hm.usuario_id = v_ator;
  if v_h is null then
    raise exception 'membresia ausente' using errcode = '23502';
  end if;

  select hm.usuario_id into v_outro
  from public.household_members hm
  where hm.household_id = v_h and hm.usuario_id <> v_ator;

  -- Sem segundo membro: no-op idempotente. Cobre tanto "nao ha nada" quanto
  -- "solicitacao unilateral ainda nao confirmada" — em ambos so o ponteiro
  -- do chamador precisa sair.
  if v_outro is null then
    update public.usuarios set parceiro_id = null
     where id = v_ator and parceiro_id is not null;
    return;
  end if;

  -- Household ativo: trava os dois em ordem estavel, igual ao vinculo.
  v_menor := least(v_ator, v_outro);
  v_maior := greatest(v_ator, v_outro);
  perform 1 from public.usuarios where id = v_menor for update;
  perform 1 from public.usuarios where id = v_maior for update;

  -- Revalida depois do lock
  select hm.household_id into v_h from public.household_members hm where hm.usuario_id = v_ator;
  select hm.usuario_id into v_outro
  from public.household_members hm
  where hm.household_id = v_h and hm.usuario_id <> v_ator;
  if v_outro is null then
    update public.usuarios set parceiro_id = null
     where id = v_ator and parceiro_id is not null;
    return;
  end if;

  -- O chamador sai para um household individual e leva SOMENTE as
  -- proprias linhas. Nenhum usuario_id muda, nada e apagado, e as linhas
  -- do outro membro ficam com ele.
  insert into public.households (criado_por) values (v_ator) returning id into v_novo;

  update public.household_members
     set household_id = v_novo, posicao = 1
   where usuario_id = v_ator;

  update public.contas      set household_id = v_novo where usuario_id = v_ator;
  update public.cartoes     set household_id = v_novo where usuario_id = v_ator;
  update public.categorias  set household_id = v_novo where usuario_id = v_ator;
  update public.lancamentos set household_id = v_novo where usuario_id = v_ator;

  update public.usuarios set parceiro_id = null where id = v_ator;

  -- Revogacao comprovada: o ponteiro unilateral que sobrar no outro
  -- perfil nao pode, sozinho, manter acesso.
  if app.sao_parceiros(v_ator, v_outro) then
    raise exception 'split invalido: o acesso compartilhado nao foi revogado'
      using errcode = '23514';
  end if;
  if (select count(*) from public.household_members where household_id = v_novo) <> 1 then
    raise exception 'split invalido: o household novo nao ficou individual'
      using errcode = '23514';
  end if;
end $$;

revoke all on function public.meu_parceiro() from public, anon;
revoke all on function public.vincular_parceiro(text) from public, anon;
revoke all on function public.desvincular_parceiro() from public, anon;
revoke all on function public.resumo_do_parceiro(date, date) from public, anon;
revoke all on function public.saldos_agregados_do_parceiro() from public, anon;

grant execute on function public.meu_parceiro() to authenticated;
grant execute on function public.vincular_parceiro(text) to authenticated;
grant execute on function public.desvincular_parceiro() to authenticated;
grant execute on function public.resumo_do_parceiro(date, date) to authenticated;
grant execute on function public.saldos_agregados_do_parceiro() to authenticated;
