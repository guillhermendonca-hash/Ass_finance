-- =====================================================================
-- 0007 — Gatilho de identidade proprio para public.usuarios
--
-- PROBLEMA
-- A 0006 instalou app.congela_identidade() nas cinco tabelas. O corpo dela
-- tem esta guarda:
--
--     if tg_table_name <> 'usuarios'
--        and new.usuario_id is distinct from old.usuario_id then
--
-- public.usuarios nao tem coluna usuario_id, e o plpgsql NAO faz
-- curto-circuito aqui: a condicao inteira vira uma expressao SQL unica e o
-- campo e resolvido de qualquer forma. Resultado, verificado em Postgres 16:
--
--     ERROR: record "new" has no field "usuario_id"
--     CONTEXT: SQL expression "tg_table_name <> 'usuarios' and ..."
--
-- Qualquer UPDATE de perfil pelo cliente falhava — inclusive o unico que a
-- interface faz, salvar nome e renda fixa mensal em Ajustes. Os testes da
-- 0006 nao pegaram porque todo caso em usuarios era negativo (recusado
-- antes pelo privilegio de coluna) e as RPCs saem na primeira guarda, por
-- serem SECURITY DEFINER.
--
-- CORRECAO
-- Uma funcao dedicada a usuarios, que nao menciona usuario_id de forma
-- alguma — nem por acesso direto, nem por SQL dinamico. Nada de depender
-- de ordem de avaliacao booleana para nao tocar um campo ausente.
--
-- Aditiva: nao altera 0001-0006. As outras quatro tabelas seguem com
-- app.congela_identidade(), onde usuario_id de fato existe.
-- =====================================================================

create or replace function app.congela_identidade_usuario()
returns trigger
language plpgsql
as $$
begin
  -- Mesma regra da 0006: so barra o que vem direto do cliente. Dentro de
  -- uma funcao SECURITY DEFINER o current_user passa a ser o dono da
  -- funcao, entao vincular_parceiro(), desvincular_parceiro() e o
  -- provisionamento seguem livres.
  if current_user <> 'authenticated' then
    return new;
  end if;

  if new.id is distinct from old.id then
    raise exception 'id e imutavel' using errcode = '42501';
  end if;

  if new.criado_em is distinct from old.criado_em then
    raise exception 'criado_em e imutavel' using errcode = '42501';
  end if;

  return new;
end $$;

-- Troca apenas o gatilho de usuarios. Os de contas, cartoes, categorias e
-- lancamentos continuam apontando para app.congela_identidade().
drop trigger if exists trg_congela_identidade on public.usuarios;
create trigger trg_congela_identidade
  before update on public.usuarios
  for each row execute function app.congela_identidade_usuario();
