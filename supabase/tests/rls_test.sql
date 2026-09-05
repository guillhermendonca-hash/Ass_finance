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

-- CAMINHO FELIZ pelas RPCs reais, nunca por UPDATE privilegiado: A declara,
-- B confirma, e e a confirmacao que funde os dois households individuais.
do $$
declare
  a_id constant uuid := '11111111-1111-4111-8111-111111111111';
  b_id constant uuid := '22222222-2222-4222-8222-222222222222';
  h_antes_a uuid; h_antes_b uuid;
begin
  select household_id into h_antes_a from public.household_members where usuario_id = a_id;
  select household_id into h_antes_b from public.household_members where usuario_id = b_id;
  perform pg_temp.assert(h_antes_a <> h_antes_b,
    'antes de qualquer vinculo, A e B estao em households individuais distintos');

  -- primeira declaracao: registra a solicitacao e nao compartilha nada
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', a_id), true);
  perform public.vincular_parceiro('b@teste.local');
  perform pg_temp.assert(not app.sao_parceiros(a_id, b_id),
    'primeira declaracao A->B nao concede acesso: ainda nao ha household comum');
  perform pg_temp.assert(
    (select household_id from public.household_members where usuario_id = a_id) = h_antes_a
    and (select household_id from public.household_members where usuario_id = b_id) = h_antes_b,
    'primeira declaracao nao move membresia nenhuma');

  -- confirmacao: aqui sim funde
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', b_id), true);
  perform public.vincular_parceiro('a@teste.local');
  perform pg_temp.assert(app.sao_parceiros(a_id, b_id),
    'a confirmacao B->A funde os dois em um household');
end $$;

-- FIXTURE ADVERSARIAL, e so isso: fabricamos um ponteiro unilateral de C
-- para A por UPDATE privilegiado, justamente para provar que um ponteiro
-- solto nao concede acesso nenhum depois do cutover.
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

  -- Na B1 isto era uma divergencia registrada: o vinculo criado depois da
  -- 0008 deixava A e B em households separados. Depois do cutover da 0009
  -- a RPC move a membresia junto, entao a sombra deixou de existir como
  -- sombra — ela E a autoridade.
  perform pg_temp.assert(
    (select household_id from public.household_members where usuario_id = a_id)
    = (select household_id from public.household_members where usuario_id = b_id),
    'A e B, vinculados pela RPC, dividem o mesmo household');
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

-- =====================================================================
-- TAR-002B2 — Vinculo e desvinculo pelas RPCs, e o que nao pode acontecer
--
-- Tres usuarios novos, para nao perturbar as fronteiras ja verificadas
-- com A, B e C. G e H formam e desfazem um casal; I e o terceiro que
-- tenta se meter.
-- =====================================================================
reset role;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'authenticated', 'authenticated', 'g@teste.local', '', now(), now(), now(),
   '{}'::jsonb, '{"nome":"Usuario G"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   'authenticated', 'authenticated', 'h@teste.local', '', now(), now(), now(),
   '{}'::jsonb, '{"nome":"Usuario H"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
   'authenticated', 'authenticated', 'i@teste.local', '', now(), now(), now(),
   '{}'::jsonb, '{"nome":"Usuario I"}'::jsonb);

insert into public.contas (id, usuario_id, nome, saldo_atual, visibilidade) values
  ('9a000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Conta de G', 500, 'casal'),
  ('9b000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Conta de H', 700, 'casal');

do $$
declare
  g_id constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  h_id constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  i_id constant uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  h_g uuid; h_h uuid; h_i uuid; n bigint; ptr uuid;
  membresias_antes jsonb; contas_antes jsonb;
begin
  raise notice 'TAR-002B2 — vinculo e desvinculo pelas RPCs:';

  select household_id into h_g from public.household_members where usuario_id = g_id;
  select household_id into h_h from public.household_members where usuario_id = h_id;
  select household_id into h_i from public.household_members where usuario_id = i_id;
  perform pg_temp.assert(h_g <> h_h and h_g <> h_i and h_h <> h_i,
    'G, H e I nascem em households individuais distintos');

  -- ============================ falha deliberada no meio do MERGE
  -- O merge termina apagando o household absorvido. Um gatilho que
  -- derruba esse DELETE quebra a RPC DEPOIS de ela ja ter movido
  -- membresia e entidades — o pior momento possivel.
  create or replace function pg_temp.falha_no_merge() returns trigger
    language plpgsql as $f$ begin raise exception 'FALHA_MERGE'; end $f$;
  execute 'create trigger trg_falha_merge before delete on public.households
             for each row execute function pg_temp.falha_no_merge()';

  select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
    into membresias_antes from public.household_members;
  select jsonb_agg(jsonb_build_array(id, usuario_id, household_id) order by id)
    into contas_antes from public.contas;

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g_id), true);
  perform public.vincular_parceiro('h@teste.local');   -- primeira declaracao, nao funde

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', h_id), true);
  begin
    perform public.vincular_parceiro('g@teste.local'); -- confirmacao: deveria fundir e falhar
    perform pg_temp.assert(false, 'o merge deveria ter falhado pelo gatilho injetado');
  exception when others then
    perform pg_temp.assert(sqlerrm like '%FALHA_MERGE%',
      'merge derrubado pela falha injetada (' || sqlerrm || ')');
  end;

  select parceiro_id into ptr from public.usuarios where id = h_id;
  perform pg_temp.assert(ptr is null,
    'MERGE REVERTIDO: o ponteiro de H nao ficou gravado');
  perform pg_temp.assert(
    membresias_antes = (select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
                          from public.household_members),
    'MERGE REVERTIDO: nenhuma membresia mudou');
  perform pg_temp.assert(
    contas_antes = (select jsonb_agg(jsonb_build_array(id, usuario_id, household_id) order by id)
                      from public.contas),
    'MERGE REVERTIDO: nenhuma conta mudou de household');

  execute 'drop trigger trg_falha_merge on public.households';

  -- ============================ merge de verdade
  perform public.vincular_parceiro('g@teste.local');
  select household_id into h_g from public.household_members where usuario_id = g_id;
  select household_id into h_h from public.household_members where usuario_id = h_id;
  perform pg_temp.assert(h_g = h_h, 'G e H foram unidos pela confirmacao');

  select count(*) into n from public.household_members where household_id = h_g;
  perform pg_temp.assert(n = 2, 'o household resultante tem exatamente dois membros');
  select count(distinct posicao) into n from public.household_members where household_id = h_g;
  perform pg_temp.assert(n = 2, 'os dois ocupam posicoes diferentes');

  select count(*) into n from public.contas
   where usuario_id in (g_id, h_id) and household_id is distinct from h_g;
  perform pg_temp.assert(n = 0, 'as contas de G e de H foram para o household do casal');

  select count(*) into n from public.households
   where not exists (select 1 from public.household_members hm where hm.household_id = households.id);
  perform pg_temp.assert(n = 0, 'o merge nao deixou household orfao');

  -- ============================ o terceiro nao entra
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', i_id), true);
  select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
    into membresias_antes from public.household_members;
  begin
    perform public.vincular_parceiro('g@teste.local');
    perform pg_temp.assert(false, 'I nao deveria entrar num household cheio');
  exception when sqlstate '22023' then
    perform pg_temp.assert(true, 'I e recusado: G ja divide household com outra pessoa');
  end;
  perform pg_temp.assert(
    membresias_antes = (select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
                          from public.household_members),
    'ESTADO FINAL: a tentativa do terceiro nao mexeu em membresia nenhuma');
  perform pg_temp.assert((select parceiro_id from public.usuarios where id = i_id) is null,
    'ESTADO FINAL: nem o ponteiro de I foi gravado');

  -- ============================ o ator ocupado tambem e recusado
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g_id), true);
  begin
    perform public.vincular_parceiro('i@teste.local');
    perform pg_temp.assert(false, 'G, ja em household de dois, nao deveria vincular com I');
  exception when sqlstate '22023' then
    perform pg_temp.assert(true, 'G e recusado: ja declarou vinculo com outra pessoa');
  end;
  perform pg_temp.assert((select parceiro_id from public.usuarios where id = g_id) = h_id,
    'ESTADO FINAL: o ponteiro de G continua apontando para H');
end $$;

-- ---------------------- H enxerga o detalhe da linha casal de G
set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated"}';

do $$
declare n bigint;
begin
  select count(*) into n from public.contas
   where usuario_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  perform pg_temp.assert(n = 1, 'H ve a conta casal de G enquanto dividem household');
end $$;

-- ============================ falha deliberada no meio do SPLIT
reset role;

do $$
declare
  g_id constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  h_id constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  h_casal uuid; n bigint;
  membresias_antes jsonb; contas_antes jsonb;
begin
  select household_id into h_casal from public.household_members where usuario_id = g_id;

  -- O split termina limpando o parceiro_id do chamador. Um gatilho que
  -- derruba exatamente esse UPDATE quebra a RPC depois de ela ja ter
  -- criado o household novo e movido membresia e entidades.
  create or replace function pg_temp.falha_no_split() returns trigger
    language plpgsql as $f$
    begin
      if new.parceiro_id is null and old.parceiro_id is not null then
        raise exception 'FALHA_SPLIT';
      end if;
      return new;
    end $f$;
  execute 'create trigger trg_falha_split before update on public.usuarios
             for each row execute function pg_temp.falha_no_split()';

  select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
    into membresias_antes from public.household_members;
  select jsonb_agg(jsonb_build_array(id, usuario_id, household_id) order by id)
    into contas_antes from public.contas;

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g_id), true);
  begin
    perform public.desvincular_parceiro();
    perform pg_temp.assert(false, 'o split deveria ter falhado pelo gatilho injetado');
  exception when others then
    perform pg_temp.assert(sqlerrm like '%FALHA_SPLIT%',
      'split derrubado pela falha injetada (' || sqlerrm || ')');
  end;

  perform pg_temp.assert(
    membresias_antes = (select jsonb_agg(jsonb_build_array(usuario_id, household_id, posicao) order by usuario_id)
                          from public.household_members),
    'SPLIT REVERTIDO: nenhuma membresia mudou');
  perform pg_temp.assert(
    contas_antes = (select jsonb_agg(jsonb_build_array(id, usuario_id, household_id) order by id)
                      from public.contas),
    'SPLIT REVERTIDO: nenhuma conta mudou de household');
  perform pg_temp.assert(app.sao_parceiros(g_id, h_id),
    'SPLIT REVERTIDO: G e H continuam no mesmo household');

  execute 'drop trigger trg_falha_split on public.usuarios';

  -- ============================ split de verdade
  perform public.desvincular_parceiro();

  perform pg_temp.assert(not app.sao_parceiros(g_id, h_id),
    'depois do desvinculo, G e H deixam de ser parceiros na hora');
  perform pg_temp.assert((select parceiro_id from public.usuarios where id = g_id) is null,
    'o ponteiro do chamador foi limpo');
  perform pg_temp.assert((select parceiro_id from public.usuarios where id = h_id) = g_id,
    'o ponteiro do OUTRO sobra apontando para G — e nao pode valer nada');

  select count(*) into n from public.household_members
   where household_id = (select household_id from public.household_members where usuario_id = g_id);
  perform pg_temp.assert(n = 1, 'G saiu para um household individual');
  select count(*) into n from public.household_members
   where household_id = (select household_id from public.household_members where usuario_id = h_id);
  perform pg_temp.assert(n = 1, 'H ficou sozinho no household que era do casal');

  -- so as linhas do chamador se mexeram
  perform pg_temp.assert(
    (select household_id from public.contas where usuario_id = g_id)
      = (select household_id from public.household_members where usuario_id = g_id),
    'a conta de G acompanhou G');
  perform pg_temp.assert(
    (select household_id from public.contas where usuario_id = h_id)
      = (select household_id from public.household_members where usuario_id = h_id),
    'a conta de H ficou com H');
  select count(*) into n from public.contas where usuario_id in (g_id, h_id);
  perform pg_temp.assert(n = 2, 'nenhuma linha foi apagada no desvinculo');
  select count(*) into n from public.contas
   where id = '9a000000-0000-4000-8000-000000000001' and usuario_id = g_id;
  perform pg_temp.assert(n = 1, 'nenhum usuario_id mudou de dono');
end $$;

-- ---------------------- H perde o detalhe na hora
set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated"}';

do $$
declare n bigint;
begin
  select count(*) into n from public.contas
   where usuario_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  perform pg_temp.assert(n = 0,
    'H deixa de ver a conta casal de G, mesmo com o ponteiro obsoleto apontando para ele');

  select count(*) into n from public.resumo_do_parceiro();
  perform pg_temp.assert(n = 0,
    'o agregado de H fica vazio: ponteiro solto nao recria parceria');
end $$;

-- ============================ relink reciproco
reset role;

do $$
declare
  g_id constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  h_id constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  n bigint;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g_id), true);
  -- H ainda aponta para G, entao esta declaracao ja e a confirmacao
  perform public.vincular_parceiro('h@teste.local');

  perform pg_temp.assert(app.sao_parceiros(g_id, h_id), 'o relink reciproco volta a unir os dois');
  select count(*) into n from public.household_members
   where household_id = (select household_id from public.household_members where usuario_id = g_id);
  perform pg_temp.assert(n = 2, 'o household reunido tem dois membros');

  select count(*) into n from public.households
   where not exists (select 1 from public.household_members hm where hm.household_id = households.id);
  perform pg_temp.assert(n = 0, 'o relink nao deixou household orfao');

  select count(*) into n from public.contas
   where usuario_id in (g_id, h_id)
     and household_id is distinct from (select household_id from public.household_members where usuario_id = g_id);
  perform pg_temp.assert(n = 0, 'as contas dos dois voltaram para o household comum');
end $$;

-- ============================ allowlist de parceiro_id
do $$
declare n bigint;
begin
  raise notice 'Allowlist de parceiro_id:';

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app'
     and p.proname in ('sao_parceiros', 'parceiro_atual', 'valida_vinculos_lancamento',
                       'household_de', 'deriva_household')
     and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform pg_temp.assert(n = 0, 'nenhum helper de autorizacao menciona parceiro_id');

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('resumo_do_parceiro', 'saldos_agregados_do_parceiro')
     and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform pg_temp.assert(n = 0, 'nenhuma funcao agregadora menciona parceiro_id');

  select count(*) into n from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') like '%parceiro_id%' or coalesce(with_check, '') like '%parceiro_id%');
  perform pg_temp.assert(n = 0, 'nenhuma policy menciona parceiro_id');

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('meu_parceiro', 'vincular_parceiro', 'desvincular_parceiro')
     and pg_get_functiondef(p.oid) like '%parceiro_id%';
  perform pg_temp.assert(n = 3,
    'as tres RPCs seguem usando parceiro_id como estado de solicitacao');
end $$;

reset role;

do $$ begin raise notice E'\nTodas as fronteiras seguraram.'; end $$;

rollback;
