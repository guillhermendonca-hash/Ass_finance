-- =====================================================================
-- 0003 — Row Level Security: as tres esferas de privacidade (secao 3)
--
--   privado              -> so o dono ve. Padrao de tudo.
--   total_compartilhado  -> o parceiro NAO ve a linha. Ve so o agregado,
--                           entregue pelas funcoes de 0004.
--   casal                -> os dois veem o detalhe e os dois editam.
--
-- A regra que sustenta a esfera do meio: 'total_compartilhado' nunca
-- entra no USING das policies de SELECT. O parceiro nao consegue ler a
-- linha nem por acidente nem de proposito — o agregado sai de funcao
-- SECURITY DEFINER que devolve soma, nunca item.
-- =====================================================================

alter table public.usuarios    enable row level security;
alter table public.contas      enable row level security;
alter table public.cartoes     enable row level security;
alter table public.categorias  enable row level security;
alter table public.lancamentos enable row level security;

-- O cliente anonimo nao toca em nada; tudo exige sessao autenticada.
revoke all on public.usuarios, public.contas, public.cartoes,
              public.categorias, public.lancamentos from anon;
grant select, insert, update, delete
  on public.usuarios, public.contas, public.cartoes,
     public.categorias, public.lancamentos to authenticated;

-- ------------------------------------------------------------ usuarios
-- Cada um le e edita so o proprio cadastro. O nome do parceiro sai pela
-- funcao public.meu_parceiro() — a linha dele continua fechada.
drop policy if exists usuarios_select on public.usuarios;
create policy usuarios_select on public.usuarios
  for select to authenticated
  using (id = auth.uid());

drop policy if exists usuarios_insert on public.usuarios;
create policy usuarios_insert on public.usuarios
  for insert to authenticated
  with check (id = auth.uid());

drop policy if exists usuarios_update on public.usuarios;
create policy usuarios_update on public.usuarios
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- -------------------------------------------------------------- contas
drop policy if exists contas_select on public.contas;
create policy contas_select on public.contas
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists contas_insert on public.contas;
create policy contas_insert on public.contas
  for insert to authenticated
  with check (usuario_id = auth.uid());

-- O parceiro edita conta do casal, mas o WITH CHECK impede que ele a
-- tire de 'casal' (ou a transfira para si) no meio da edicao.
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

drop policy if exists contas_delete on public.contas;
create policy contas_delete on public.contas
  for delete to authenticated
  using (usuario_id = auth.uid());

-- ------------------------------------------------------------- cartoes
drop policy if exists cartoes_select on public.cartoes;
create policy cartoes_select on public.cartoes
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists cartoes_insert on public.cartoes;
create policy cartoes_insert on public.cartoes
  for insert to authenticated
  with check (usuario_id = auth.uid());

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

drop policy if exists cartoes_delete on public.cartoes;
create policy cartoes_delete on public.cartoes
  for delete to authenticated
  using (usuario_id = auth.uid());

-- ---------------------------------------------------------- categorias
-- Categoria e sempre pessoal. O parceiro nunca le esta tabela: quando
-- precisa do nome da categoria para exibir um agregado, ele vem junto
-- do proprio agregado.
drop policy if exists categorias_todas on public.categorias;
create policy categorias_todas on public.categorias
  for all to authenticated
  using (usuario_id = auth.uid())
  with check (usuario_id = auth.uid());

-- --------------------------------------------------------- lancamentos
-- Aqui mora a esfera do meio: 'total_compartilhado' esta ausente de
-- proposito do USING. So 'casal' atravessa para o parceiro.
drop policy if exists lancamentos_select on public.lancamentos;
create policy lancamentos_select on public.lancamentos
  for select to authenticated
  using (
    usuario_id = auth.uid()
    or (visibilidade = 'casal' and app.sao_parceiros(auth.uid(), usuario_id))
  );

drop policy if exists lancamentos_insert on public.lancamentos;
create policy lancamentos_insert on public.lancamentos
  for insert to authenticated
  with check (usuario_id = auth.uid());

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
