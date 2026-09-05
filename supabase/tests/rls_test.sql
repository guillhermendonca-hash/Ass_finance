-- =====================================================================
-- Teste das tres esferas de privacidade.
--
--   psql "$DATABASE_URL" -f supabase/tests/rls_test.sql
--
-- Precisa de conexao com papel privilegiado (postgres), porque troca de
-- role para simular cada usuario. Roda inteiro dentro de uma transacao
-- e termina com ROLLBACK: nao deixa nada no banco.
--
-- Qualquer vazamento derruba o script com ERROR. Silencio = passou.
-- =====================================================================

begin;

set local client_min_messages to notice;

create or replace function pg_temp.assert(cond boolean, msg text)
returns void language plpgsql as $$
begin
  if not cond then
    raise exception 'FALHOU -> %', msg;
  end if;
  raise notice '  ok  %', msg;
end $$;

-- Guilherme = A, parceira = B, estranho = C
create temporary table ids (rotulo text primary key, id uuid) on commit drop;
insert into ids values
  ('A', '11111111-1111-4111-8111-111111111111'),
  ('B', '22222222-2222-4222-8222-222222222222'),
  ('C', '33333333-3333-4333-8333-333333333333');

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select '00000000-0000-0000-0000-000000000000', i.id, 'authenticated', 'authenticated',
       lower(i.rotulo) || '@teste.local', '', now(), now(), now(),
       '{"provider":"email"}'::jsonb,
       jsonb_build_object('nome', 'Usuario ' || i.rotulo)
from ids i;

-- Vinculo reciproco entre A e B. C aponta para A, mas A nao aponta de
-- volta: e o caso do vinculo unilateral, que nao pode valer nada.
update public.usuarios set parceiro_id = (select id from ids where rotulo = 'B')
  where id = (select id from ids where rotulo = 'A');
update public.usuarios set parceiro_id = (select id from ids where rotulo = 'A')
  where id = (select id from ids where rotulo = 'B');
update public.usuarios set parceiro_id = (select id from ids where rotulo = 'A')
  where id = (select id from ids where rotulo = 'C');

-- Dados de A, um em cada esfera (insercao como superusuario: setup).
insert into public.contas (id, usuario_id, nome, saldo_atual, visibilidade) values
  ('aa000000-0000-4000-8000-000000000001', (select id from ids where rotulo='A'), 'Corrente A',  1000, 'privado'),
  ('aa000000-0000-4000-8000-000000000002', (select id from ids where rotulo='A'), 'Poupança A',   500, 'total_compartilhado'),
  ('aa000000-0000-4000-8000-000000000003', (select id from ids where rotulo='A'), 'Conjunta',    2000, 'casal'),
  ('bb000000-0000-4000-8000-000000000001', (select id from ids where rotulo='B'), 'Corrente B',   800, 'privado');

-- Conta com carimbo antigo: trg_atualizado_em so dispara em UPDATE, entao o
-- valor abaixo sobrevive ao insert e serve de marco para o teste do gatilho.
insert into public.contas (id, usuario_id, nome, saldo_atual, visibilidade, atualizado_em)
values ('aa000000-0000-4000-8000-000000000004', (select id from ids where rotulo='A'),
        'Carimbo', 10, 'privado', timestamptz '2000-01-01 00:00:00+00');

insert into public.cartoes (id, usuario_id, nome, limite, dia_fechamento, dia_vencimento, visibilidade)
values ('cc000000-0000-4000-8000-000000000001', (select id from ids where rotulo='A'),
        'Cartao conjunto', 5000, 10, 17, 'casal');

insert into public.lancamentos (usuario_id, tipo, valor, classe, descricao, visibilidade, categoria_id, data)
select (select id from ids where rotulo='A'), 'gasto', v.valor, 'variavel', v.descr, v.vis,
       (select id from public.categorias where usuario_id = (select id from ids where rotulo='A') and nome = 'Lazer'),
       current_date
from (values
  (100.00, 'terapia (segredo de A)',  'privado'::public.visibilidade),
  (200.00, 'mercado do mes',          'total_compartilhado'),
  (300.00, 'aluguel conjunto',        'casal')
) as v(valor, descr, vis);

-- =====================================================================
-- B (parceira confirmada) olhando para os dados de A
-- =====================================================================
set local role authenticated;
set local request.jwt.claims to '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';

do $$
declare
  n bigint;
  linha record;
begin
  raise notice 'B (parceira confirmada) sobre os dados de A:';

  select count(*) into n from public.lancamentos
   where usuario_id = '11111111-1111-4111-8111-111111111111'
     and visibilidade = 'privado';
  perform pg_temp.assert(n = 0, 'lancamento privado de A e invisivel para B');

  select count(*) into n from public.lancamentos
   where usuario_id = '11111111-1111-4111-8111-111111111111'
     and visibilidade = 'total_compartilhado';
  perform pg_temp.assert(n = 0, 'lancamento total_compartilhado de A nao vaza a LINHA para B');

  select count(*) into n from public.lancamentos
   where usuario_id = '11111111-1111-4111-8111-111111111111'
     and visibilidade = 'casal';
  perform pg_temp.assert(n = 1, 'lancamento do casal chega inteiro para B');

  -- descricao do item privado nao pode aparecer em lugar nenhum
  select count(*) into n from public.lancamentos where descricao ilike '%segredo%';
  perform pg_temp.assert(n = 0, 'a descricao do item privado de A nao aparece em nenhuma query de B');

  select count(*) into n from public.contas
   where usuario_id = '11111111-1111-4111-8111-111111111111';
  perform pg_temp.assert(n = 1, 'das 4 contas de A, B enxerga so a do casal');

  select count(*) into n from public.usuarios
   where id = '11111111-1111-4111-8111-111111111111';
  perform pg_temp.assert(n = 0, 'a linha de cadastro de A (renda inclusive) fica fechada para B');

  select count(*) into n from public.categorias
   where usuario_id = '11111111-1111-4111-8111-111111111111';
  perform pg_temp.assert(n = 0, 'as categorias de A sao pessoais e nao chegam a B');

  -- ---------------- o agregado: soma o que a linha nao entrega
  select count(*) into n from public.resumo_do_parceiro();
  perform pg_temp.assert(n > 0, 'resumo_do_parceiro() devolve o agregado de A para B');

  select coalesce(sum(total), 0) into n from public.resumo_do_parceiro()
   where escopo = 'total_compartilhado';
  perform pg_temp.assert(n = 200, 'o agregado soma os R$ 200 do total_compartilhado');

  select count(*) into n from public.resumo_do_parceiro() where escopo = 'privado';
  perform pg_temp.assert(n = 0, 'o agregado NUNCA inclui a esfera privada');

  select coalesce(sum(saldo_em_contas), 0) into n from public.saldos_agregados_do_parceiro();
  perform pg_temp.assert(n = 500, 'saldo agregado traz so a conta total_compartilhado (R$ 500)');
end $$;

-- =====================================================================
-- B tentando escrever onde nao deve
-- =====================================================================
do $$
declare n integer;
begin
  raise notice 'B tentando escrever nos dados de A:';

  update public.lancamentos set valor = 1
   where usuario_id = '11111111-1111-4111-8111-111111111111' and visibilidade = 'privado';
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 0, 'B nao consegue editar lancamento privado de A');

  update public.lancamentos set valor = 350
   where usuario_id = '11111111-1111-4111-8111-111111111111' and visibilidade = 'casal';
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'B PODE editar o lancamento do casal (secao 3: ambos editam)');

  begin
    update public.lancamentos set visibilidade = 'privado'
     where usuario_id = '11111111-1111-4111-8111-111111111111' and visibilidade = 'casal';
    perform pg_temp.assert(false, 'B nao deveria tirar o lancamento da esfera casal');
  exception when insufficient_privilege or check_violation then
    perform pg_temp.assert(true, 'B nao consegue tirar o lancamento do casal da esfera compartilhada');
  end;

  begin
    insert into public.lancamentos (usuario_id, tipo, valor, classe, visibilidade)
    values ('11111111-1111-4111-8111-111111111111', 'gasto', 50, 'variavel', 'casal');
    perform pg_temp.assert(false, 'B nao deveria lancar em nome de A');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'B nao consegue criar lancamento em nome de A');
  end;
end $$;

-- =====================================================================
-- C: apontou para A, mas A nao apontou de volta. Vinculo unilateral
-- nao pode abrir porta nenhuma.
-- =====================================================================
set local request.jwt.claims to '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';

do $$
declare n bigint;
begin
  raise notice 'C (vinculo unilateral, nao correspondido por A):';

  select count(*) into n from public.lancamentos
   where usuario_id = '11111111-1111-4111-8111-111111111111';
  perform pg_temp.assert(n = 0, 'C nao ve NENHUM lancamento de A, nem os do casal');

  select count(*) into n from public.contas
   where usuario_id = '11111111-1111-4111-8111-111111111111';
  perform pg_temp.assert(n = 0, 'C nao ve nenhuma conta de A');

  select count(*) into n from public.resumo_do_parceiro();
  perform pg_temp.assert(n = 0, 'o agregado fica vazio: sem reciprocidade nao ha parceria');
end $$;

-- =====================================================================
-- A (dono) continua vendo o proprio detalhe inteiro
-- =====================================================================
set local request.jwt.claims to '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';

do $$
declare n bigint;
begin
  raise notice 'A (dono) sobre os proprios dados:';

  select count(*) into n from public.lancamentos where usuario_id = auth.uid();
  perform pg_temp.assert(n = 3, 'A ve os proprios 3 lancamentos, em qualquer esfera');

  select count(*) into n from public.contas where usuario_id = auth.uid();
  perform pg_temp.assert(n = 4, 'A ve as proprias 4 contas');

  select count(*) into n from public.categorias where usuario_id = auth.uid();
  perform pg_temp.assert(n = 13, 'A recebeu as 13 categorias iniciais no cadastro');
end $$;

-- =====================================================================
-- Saldo da conta e integridade dos vinculos (secao 5.2)
-- =====================================================================
do $$
declare v numeric;
begin
  raise notice 'Saldo da conta e integridade dos vinculos:';

  insert into public.lancamentos (usuario_id, tipo, valor, classe, conta_id, visibilidade)
  values (auth.uid(), 'gasto', 100, 'variavel', 'aa000000-0000-4000-8000-000000000001', 'privado');
  select saldo_atual into v from public.contas where id = 'aa000000-0000-4000-8000-000000000001';
  perform pg_temp.assert(v = 900, 'gasto de R$ 100 baixou a conta de 1000 para 900');

  insert into public.lancamentos (usuario_id, tipo, valor, classe, conta_id, visibilidade)
  values (auth.uid(), 'receita', 250, 'receita', 'aa000000-0000-4000-8000-000000000001', 'privado');
  select saldo_atual into v from public.contas where id = 'aa000000-0000-4000-8000-000000000001';
  perform pg_temp.assert(v = 1150, 'receita de R$ 250 subiu a conta para 1150');

  update public.lancamentos set valor = 400
   where conta_id = 'aa000000-0000-4000-8000-000000000001' and tipo = 'gasto';
  select saldo_atual into v from public.contas where id = 'aa000000-0000-4000-8000-000000000001';
  perform pg_temp.assert(v = 850, 'editar o gasto para R$ 400 reajustou o saldo para 850');

  delete from public.lancamentos where conta_id = 'aa000000-0000-4000-8000-000000000001';
  select saldo_atual into v from public.contas where id = 'aa000000-0000-4000-8000-000000000001';
  perform pg_temp.assert(v = 1000, 'apagar os lancamentos devolveu a conta ao saldo original');

  begin
    insert into public.lancamentos (usuario_id, tipo, valor, classe, conta_id, visibilidade)
    values (auth.uid(), 'gasto', 10, 'variavel', 'bb000000-0000-4000-8000-000000000001', 'privado');
    perform pg_temp.assert(false, 'A nao deveria lancar na conta privada de B');
  exception when check_violation then
    perform pg_temp.assert(true, 'A nao consegue lancar na conta privada de B');
  end;

  begin
    insert into public.lancamentos (usuario_id, tipo, valor, classe, visibilidade)
    values (auth.uid(), 'receita', 10, 'variavel', 'privado');
    perform pg_temp.assert(false, 'receita nao deveria aceitar classe variavel');
  exception when check_violation then
    perform pg_temp.assert(true, 'receita so aceita classe receita (classe_coerente_com_tipo)');
  end;
end $$;

-- =====================================================================
-- TAR-002A — Posse da linha e colunas editaveis
--
-- O ataque que motivou a hotfix: o parceiro edita uma linha 'casal' e, na
-- MESMA instrucao, troca usuario_id para si e visibilidade para 'privado'.
-- O USING olhava a linha ANTIGA (casal, do parceiro reciproco) e o WITH
-- CHECK olhava a linha NOVA (dele) — os dois passavam. Sem privilegio por
-- coluna, a linha trocava de dono e o dono original perdia acesso.
--
-- Cada ataque confere tambem o ESTADO FINAL da linha: capturar a excecao
-- nao basta, porque uma excecao no lugar errado passaria por defesa.
-- =====================================================================
do $$
declare
  a_id         constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id         constant uuid := '22222222-2222-4222-8222-222222222222';
  conta_casal  constant uuid := 'aa000000-0000-4000-8000-000000000003';
  cartao_casal constant uuid := 'cc000000-0000-4000-8000-000000000001';
  conta_carimbo constant uuid := 'aa000000-0000-4000-8000-000000000004';
  como_a       constant text := format('{"sub":"%s","role":"authenticated"}', '11111111-1111-4111-8111-111111111111');
  como_b       constant text := format('{"sub":"%s","role":"authenticated"}', '22222222-2222-4222-8222-222222222222');
  lanc_casal   uuid;
  dono         uuid;
  vis          public.visibilidade;
  txt          text;
  saldo        numeric;
  carimbo      timestamptz;
  parceiro     uuid;
begin
  raise notice 'TAR-002A — posse da linha e colunas editaveis:';

  perform set_config('request.jwt.claims', como_a, true);
  select id into lanc_casal
    from public.lancamentos
   where usuario_id = a_id and visibilidade = 'casal'
   limit 1;

  -- ============================================ B tenta se apropriar
  perform set_config('request.jwt.claims', como_b, true);

  begin
    update public.contas
       set usuario_id = b_id, visibilidade = 'privado'
     where id = conta_casal;
    perform pg_temp.assert(false, 'B nao deveria se apropriar da conta do casal');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'conta: o UPDATE combinado usuario_id+visibilidade e recusado');
  end;

  begin
    update public.cartoes
       set usuario_id = b_id, visibilidade = 'privado'
     where id = cartao_casal;
    perform pg_temp.assert(false, 'B nao deveria se apropriar do cartao do casal');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'cartao: o UPDATE combinado e recusado');
  end;

  begin
    update public.lancamentos
       set usuario_id = b_id, visibilidade = 'privado'
     where id = lanc_casal;
    perform pg_temp.assert(false, 'B nao deveria se apropriar do lancamento do casal');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'lancamento: o UPDATE combinado e recusado');
  end;

  -- tirar da esfera compartilhada, sozinho, continua barrado pelo WITH CHECK
  begin
    update public.contas set visibilidade = 'privado' where id = conta_casal;
    perform pg_temp.assert(false, 'B nao deveria tirar a conta da esfera casal');
  exception when insufficient_privilege or check_violation then
    perform pg_temp.assert(true, 'conta: B nao consegue tirar a linha da esfera casal');
  end;

  -- ================================= estado final, conferido como A
  perform set_config('request.jwt.claims', como_a, true);

  select usuario_id, visibilidade into dono, vis from public.contas where id = conta_casal;
  perform pg_temp.assert(dono = a_id and vis = 'casal',
    'ESTADO FINAL conta: continua de A e continua casal');

  select usuario_id, visibilidade into dono, vis from public.cartoes where id = cartao_casal;
  perform pg_temp.assert(dono = a_id and vis = 'casal',
    'ESTADO FINAL cartao: continua de A e continua casal');

  select usuario_id, visibilidade into dono, vis from public.lancamentos where id = lanc_casal;
  perform pg_temp.assert(dono = a_id and vis = 'casal',
    'ESTADO FINAL lancamento: continua de A e continua casal');

  -- ==================== nem o proprio dono muda a posse por UPDATE
  begin
    update public.contas set usuario_id = b_id where id = conta_casal;
    perform pg_temp.assert(false, 'A nao deveria transferir a propria conta por UPDATE');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'nem o dono muda usuario_id por UPDATE');
  end;

  select usuario_id into dono from public.contas where id = conta_casal;
  perform pg_temp.assert(dono = a_id, 'ESTADO FINAL: a conta continua de A depois da tentativa');

  -- ============================ colunas fechadas em public.usuarios
  begin
    update public.usuarios set email = 'sequestrado@teste.local' where id = a_id;
    perform pg_temp.assert(false, 'o cliente nao deveria alterar o proprio email');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'usuarios.email nao e editavel pelo cliente');
  end;

  begin
    update public.usuarios set parceiro_id = null where id = a_id;
    perform pg_temp.assert(false, 'o cliente nao deveria mexer em parceiro_id direto');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'usuarios.parceiro_id so muda pelas RPCs');
  end;

  select email, parceiro_id into txt, parceiro from public.usuarios where id = a_id;
  perform pg_temp.assert(txt = 'a@teste.local' and parceiro = b_id,
    'ESTADO FINAL usuarios: email e vinculo intactos');

  begin
    update public.contas set atualizado_em = timestamptz '2000-01-01' where id = conta_casal;
    perform pg_temp.assert(false, 'o cliente nao deveria forjar atualizado_em');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'atualizado_em nao e concedida ao cliente');
  end;

  -- ==================================== o que DEVE continuar funcionando
  update public.contas set nome = 'Conjunta renomeada' where id = conta_casal;
  select nome, usuario_id into txt, dono from public.contas where id = conta_casal;
  perform pg_temp.assert(txt = 'Conjunta renomeada' and dono = a_id,
    'o dono edita campo funcional, e a posse nao muda');

  -- o gatilho continua carimbando, mesmo sem a coluna concedida
  update public.contas set nome = 'Carimbo tocado' where id = conta_carimbo;
  select atualizado_em into carimbo from public.contas where id = conta_carimbo;
  perform pg_temp.assert(carimbo > timestamptz '2001-01-01',
    'trg_atualizado_em ainda carimba (era 2000-01-01 antes do UPDATE)');

  perform set_config('request.jwt.claims', como_b, true);
  update public.contas set saldo_atual = 2500 where id = conta_casal;
  select saldo_atual, usuario_id, visibilidade into saldo, dono, vis
    from public.contas where id = conta_casal;
  perform pg_temp.assert(saldo = 2500 and dono = a_id and vis = 'casal',
    'o parceiro edita campo funcional da linha casal, sem tocar posse nem esfera');

  -- =========================== as RPCs de vinculo seguem funcionando
  perform set_config('request.jwt.claims', como_a, true);

  perform public.desvincular_parceiro();
  select parceiro_id into parceiro from public.usuarios where id = a_id;
  perform pg_temp.assert(parceiro is null, 'desvincular_parceiro() ainda desfaz o vinculo');

  perform public.vincular_parceiro('b@teste.local');
  select parceiro_id into parceiro from public.usuarios where id = a_id;
  perform pg_temp.assert(parceiro = b_id, 'vincular_parceiro() ainda refaz o vinculo');
end $$;

-- =====================================================================
-- TAR-002A-C1 — Edicao do proprio perfil
--
-- A 0006 quebrou este caminho: app.congela_identidade() acessava
-- new.usuario_id, campo que public.usuarios nao tem, e o plpgsql nao faz
-- curto-circuito na condicao. Todo UPDATE de perfil pelo cliente morria
-- com 'record "new" has no field "usuario_id"'.
--
-- Os testes da 0006 nao pegaram porque todos os casos em usuarios eram
-- NEGATIVOS: paravam no privilegio de coluna antes de chegar ao gatilho.
-- Faltava exatamente isto, um caso positivo.
-- =====================================================================
set local request.jwt.claims to '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';

do $$
declare
  funcao       text;
  nome_final   text;
  renda_final  numeric;
begin
  raise notice 'TAR-002A-C1 — edicao do proprio perfil:';

  select p.proname into funcao
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.usuarios'::regclass
     and t.tgname = 'trg_congela_identidade';
  perform pg_temp.assert(funcao = 'congela_identidade_usuario',
    'usuarios usa a funcao dedicada, nao a das tabelas com usuario_id');

  -- Exatamente o que a tela de Ajustes envia ao salvar.
  update public.usuarios
     set nome = 'Guilherme Mendonca',
         renda_fixa_mensal = 5200.00
   where id = auth.uid();

  select nome, renda_fixa_mensal into nome_final, renda_final
    from public.usuarios where id = auth.uid();

  perform pg_temp.assert(nome_final = 'Guilherme Mendonca',
    'o nome do proprio perfil persiste depois do UPDATE');
  perform pg_temp.assert(renda_final = 5200.00,
    'a renda fixa mensal do proprio perfil persiste depois do UPDATE');
end $$;

-- ---------------------------------------------------------------------
-- A defesa em profundidade da 0007, exercitada de verdade.
--
-- Com os grants da 0006 no lugar, o corpo da funcao nunca roda: o
-- privilegio de coluna recusa antes. Concedemos criado_em temporariamente
-- para simular o cenario que essa defesa existe para cobrir — uma migracao
-- futura reconceder UPDATE amplo por engano. Tudo dentro da transacao do
-- teste, desfeito no rollback final.
--
-- criado_em, e nao id: uma troca de id tambem bateria no WITH CHECK do RLS,
-- que levanta o mesmo 42501, e ai nao daria para saber quem barrou.
-- ---------------------------------------------------------------------
reset role;
grant update (criado_em) on public.usuarios to authenticated;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';

do $$
declare criado_final timestamptz;
begin
  begin
    update public.usuarios set criado_em = timestamptz '2000-01-01' where id = auth.uid();
    perform pg_temp.assert(false, 'o gatilho deveria barrar a troca de criado_em');
  exception when insufficient_privilege then
    perform pg_temp.assert(sqlerrm like '%criado_em%',
      'usuarios: o gatilho barra criado_em mesmo com a coluna concedida (' || sqlerrm || ')');
  end;

  select criado_em into criado_final from public.usuarios where id = auth.uid();
  perform pg_temp.assert(criado_final > timestamptz '2001-01-01',
    'ESTADO FINAL: criado_em do perfil continua o original');
end $$;

reset role;
revoke update (criado_em) on public.usuarios from authenticated;

-- =====================================================================
-- TAR-002B1 — Fundacao shadow de households
--
-- ATENCAO a uma divergencia esperada nesta fatia: aqui as migracoes ja
-- estao todas aplicadas quando os usuarios sao criados, entao o household
-- de cada um vem do PROVISIONAMENTO (individual), nao do backfill. A e B
-- sao parceiros reciprocos e mesmo assim ficam em households diferentes,
-- porque a 0008 nao sincroniza vinculos criados depois dela. Isso e o
-- comportamento correto da B1 e o motivo de nao haver deploy entre B1 e B2.
-- O backfill sobre dados preexistentes e coberto pelo outro arnes,
-- run_households_backfill.sh.
-- =====================================================================
reset role;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000', 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        'authenticated', 'authenticated', 'f@teste.local', '', now(), now(), now(),
        '{"provider":"email"}'::jsonb, '{"nome":"Usuario F"}'::jsonb);

do $$
declare
  f_id constant uuid := 'ffffffff-ffff-4fff-8fff-ffffffffffff';
  a_id constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id constant uuid := '22222222-2222-4222-8222-222222222222';
  h_f uuid; p_f smallint; n bigint;
begin
  raise notice 'TAR-002B1 — fundacao de households:';

  perform pg_temp.assert(
    exists (select 1 from public.usuarios where id = f_id),
    'novo auth.users gera a linha em public.usuarios');

  select household_id, posicao into h_f, p_f
    from public.household_members where usuario_id = f_id;
  perform pg_temp.assert(h_f is not null and p_f = 1,
    'novo usuario nasce com household individual e membresia posicao 1');

  select count(*) into n from public.household_members where household_id = h_f;
  perform pg_temp.assert(n = 1, 'o household do novo usuario tem so ele');

  select count(*) into n from public.categorias where usuario_id = f_id;
  perform pg_temp.assert(n = 13, 'as 13 categorias iniciais continuam sendo semeadas');

  select count(*) into n from public.categorias
   where usuario_id = f_id and household_id is distinct from h_f;
  perform pg_temp.assert(n = 0,
    'as categorias do provisionamento ja nascem com o household derivado');

  -- A divergencia esperada da B1, registrada como asserção para nao passar
  -- despercebida no cutover da B2.
  perform pg_temp.assert(
    (select household_id from public.household_members where usuario_id = a_id)
    <> (select household_id from public.household_members where usuario_id = b_id),
    'SOMBRA: A e B sao parceiros reciprocos mas seguem em households separados '
    '(vinculo criado depois da 0008; a B2 reconcilia)');
end $$;

-- ------------------------------------- derivacao nos quatro tipos
-- Os ids de household viajam por GUC porque o cliente NAO pode ler
-- household_members — ler dali dentro do bloco furaria a propria sombra
-- que estamos testando.
do $$
begin
  perform set_config('teste.h_f',
    (select household_id::text from public.household_members
      where usuario_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'), true);
  perform set_config('teste.h_a',
    (select household_id::text from public.household_members
      where usuario_id = '11111111-1111-4111-8111-111111111111'), true);
end $$;

set local role authenticated;
set local request.jwt.claims to '{"sub":"ffffffff-ffff-4fff-8fff-ffffffffffff","role":"authenticated"}';

do $$
declare
  h_f uuid := current_setting('teste.h_f')::uuid;
  h_a uuid := current_setting('teste.h_a')::uuid;
  id_conta uuid; id_cartao uuid; id_categoria uuid; id_lanc uuid;
  n bigint;
begin
  insert into public.contas (usuario_id, nome, saldo_atual, visibilidade)
  values (auth.uid(), 'Conta de F', 100, 'privado') returning id into id_conta;
  insert into public.cartoes (usuario_id, nome, limite, dia_fechamento, dia_vencimento, visibilidade)
  values (auth.uid(), 'Cartao de F', 1000, 10, 17, 'privado') returning id into id_cartao;
  insert into public.categorias (usuario_id, nome, classe_padrao, cor)
  values (auth.uid(), 'Categoria de F', 'variavel', '#123456') returning id into id_categoria;
  insert into public.lancamentos (usuario_id, tipo, valor, classe, categoria_id, visibilidade)
  values (auth.uid(), 'gasto', 25, 'variavel', id_categoria, 'privado') returning id into id_lanc;

  perform pg_temp.assert(
    (select household_id from public.contas where id = id_conta) = h_f,
    'conta nova deriva o household do dono');
  perform pg_temp.assert(
    (select household_id from public.cartoes where id = id_cartao) = h_f,
    'cartao novo deriva o household do dono');
  perform pg_temp.assert(
    (select household_id from public.categorias where id = id_categoria) = h_f,
    'categoria nova deriva o household do dono');
  perform pg_temp.assert(
    (select household_id from public.lancamentos where id = id_lanc) = h_f,
    'lancamento novo deriva o household do dono');

  -- payload forjado com o household de terceiro: o gatilho sobrescreve
  insert into public.contas (usuario_id, nome, saldo_atual, visibilidade, household_id)
  values (auth.uid(), 'Conta forjada', 10, 'privado', h_a) returning id into id_conta;
  perform pg_temp.assert(
    (select household_id from public.contas where id = id_conta) = h_f,
    'household forjado no INSERT nao persiste: e sobrescrito pelo do dono');

  insert into public.lancamentos (usuario_id, tipo, valor, classe, visibilidade, household_id)
  values (auth.uid(), 'gasto', 5, 'variavel', 'privado', h_a) returning id into id_lanc;
  perform pg_temp.assert(
    (select household_id from public.lancamentos where id = id_lanc) = h_f,
    'household forjado em lancamento tambem e sobrescrito');

  select count(*) into n from public.contas where household_id = h_a and usuario_id = auth.uid();
  perform pg_temp.assert(n = 0,
    'ESTADO FINAL: nenhuma linha de F ficou apontando para o household de A');

  -- household_id nao esta nos grants de UPDATE da 0006
  begin
    update public.contas set household_id = h_a where usuario_id = auth.uid();
    perform pg_temp.assert(false, 'household_id nao deveria ser editavel pelo cliente');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'household_id nao foi concedida no UPDATE por coluna');
  end;
end $$;

-- --------------------------- a sombra e fechada ao cliente
do $$
declare n bigint;
begin
  raise notice 'A sombra e inacessivel ao cliente:';

  begin
    select count(*) into n from public.households;
    perform pg_temp.assert(false, 'authenticated nao deveria ler households');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao le households');
  end;

  begin
    select count(*) into n from public.household_members;
    perform pg_temp.assert(false, 'authenticated nao deveria ler household_members');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao le household_members');
  end;

  begin
    insert into public.households (criado_por) values (auth.uid());
    perform pg_temp.assert(false, 'authenticated nao deveria inserir household');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao insere household');
  end;

  begin
    insert into public.household_members (household_id, usuario_id, posicao)
    values (gen_random_uuid(), auth.uid(), 2);
    perform pg_temp.assert(false, 'authenticated nao deveria criar membresia');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao cria membresia');
  end;

  begin
    update public.household_members set posicao = 2 where usuario_id = auth.uid();
    perform pg_temp.assert(false, 'authenticated nao deveria alterar membresia');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao altera membresia');
  end;

  begin
    delete from public.household_members where usuario_id = auth.uid();
    perform pg_temp.assert(false, 'authenticated nao deveria apagar membresia');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'authenticated nao apaga membresia');
  end;

  begin
    perform app.household_de(auth.uid());
    perform pg_temp.assert(false, 'o helper interno nao deveria ser executavel pelo cliente');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'app.household_de nao e executavel por authenticated');
  end;
end $$;

set local role anon;

do $$
declare n bigint;
begin
  begin
    select count(*) into n from public.households;
    perform pg_temp.assert(false, 'anon nao deveria ler households');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'anon nao le households');
  end;

  begin
    insert into public.household_members (household_id, usuario_id, posicao)
    values (gen_random_uuid(), gen_random_uuid(), 1);
    perform pg_temp.assert(false, 'anon nao deveria escrever membresia');
  exception when insufficient_privilege then
    perform pg_temp.assert(true, 'anon nao escreve membresia');
  end;
end $$;

-- ------------------------------ catalogo: gatilhos e privilegios
reset role;

do $$
declare n bigint;
begin
  raise notice 'Catalogo de gatilhos e privilegios:';

  select count(*) into n
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgname = 'trg_congela_identidade'
     and t.tgrelid = 'public.usuarios'::regclass
     and p.proname = 'congela_identidade_usuario';
  perform pg_temp.assert(n = 1, 'usuarios usa congela_identidade_usuario');

  select count(*) into n
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgname = 'trg_congela_identidade'
     and t.tgrelid in ('public.contas'::regclass, 'public.cartoes'::regclass,
                       'public.categorias'::regclass, 'public.lancamentos'::regclass)
     and p.proname = 'congela_identidade';
  perform pg_temp.assert(n = 4, 'as quatro tabelas com usuario_id usam congela_identidade');

  select count(*) into n
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgname = 'trg_deriva_household'
     and t.tgrelid in ('public.contas'::regclass, 'public.cartoes'::regclass,
                       'public.categorias'::regclass, 'public.lancamentos'::regclass)
     and p.proname = 'deriva_household';
  perform pg_temp.assert(n = 4, 'as quatro tabelas derivam household por gatilho');

  select count(*) into n from information_schema.table_privileges
   where grantee = 'authenticated' and table_schema = 'public' and privilege_type = 'UPDATE';
  perform pg_temp.assert(n = 0,
    'NENHUMA tabela de public tem UPDATE de tabela inteira para authenticated');

  select count(*) into n from information_schema.column_privileges
   where grantee = 'authenticated' and table_schema = 'public' and privilege_type = 'UPDATE';
  perform pg_temp.assert(n = 26,
    'os 26 grants de UPDATE por coluna da 0006 continuam valendo');

  select count(*) into n from information_schema.column_privileges
   where grantee = 'authenticated' and table_schema = 'public'
     and privilege_type = 'UPDATE' and column_name = 'household_id';
  perform pg_temp.assert(n = 0, 'household_id nao entrou em nenhum grant de UPDATE');

  select count(*) into n from information_schema.table_privileges
   where grantee in ('anon', 'authenticated') and table_schema = 'public'
     and table_name in ('households', 'household_members');
  perform pg_temp.assert(n = 0,
    'households e household_members nao tem privilegio algum para anon nem authenticated');
end $$;

set local role authenticated;

reset role;

do $$ begin raise notice E'\nTodas as fronteiras seguraram.'; end $$;

rollback;
