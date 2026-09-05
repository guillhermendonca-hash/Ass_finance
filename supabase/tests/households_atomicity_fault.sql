-- =====================================================================
-- Falha injetada, para provar que a 0008 e atomica.
--
-- Instala um gatilho BEFORE UPDATE em public.cartoes que sempre levanta a
-- mesma mensagem. A 0008 atualiza contas ANTES de cartoes, entao quando
-- este gatilho dispara a migracao ja criou tabelas, adicionou colunas,
-- populou households e DESABILITOU os quatro trg_atualizado_em. E
-- exatamente o ponto em que um rollback parcial deixaria o banco torto.
--
-- Aplicado depois do setup e antes da primeira tentativa da 0008.
-- Removido pelo runner apos as assercoes.
-- =====================================================================

create or replace function teste_backfill.falha_injetada()
returns trigger
language plpgsql
as $$
begin
  raise exception 'FALHA_INJETADA_0008';
end $$;

drop trigger if exists trg_falha_injetada on public.cartoes;
create trigger trg_falha_injetada
  before update on public.cartoes
  for each row execute function teste_backfill.falha_injetada();

do $$ begin raise notice 'falha injetada armada em public.cartoes'; end $$;
