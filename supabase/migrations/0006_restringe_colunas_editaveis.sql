-- =====================================================================
-- 0006 — Privilégios de UPDATE por coluna (hotfix de ownership)
--
-- PROBLEMA
-- 0003 concedeu UPDATE de tabela inteira a `authenticated`. As policies de
-- UPDATE avaliam o USING na linha ANTIGA e o WITH CHECK na linha NOVA, e
-- ambos aceitam `usuario_id = auth.uid()`. Um parceiro com acesso a uma
-- linha 'casal' podia então executar:
--
--     update public.contas
--        set usuario_id = <id dele>, visibilidade = 'privado'
--      where id = <linha do casal>;
--
-- O USING passava (linha antiga era 'casal' de um parceiro recíproco) e o
-- WITH CHECK passava (linha nova pertencia a quem executava). Resultado:
-- a linha trocava de dono e saía da esfera compartilhada, e o dono
-- original perdia acesso ao próprio registro.
--
-- CORREÇÃO
-- RLS decide QUAIS LINHAS o cliente alcança; ela não decide QUAIS COLUNAS.
-- Quem faz isso é o privilégio por coluna. Revogamos o UPDATE de tabela e
-- concedemos apenas as colunas funcionais — `usuario_id`, `id` e
-- `criado_em` deixam de ser endereçáveis pelo cliente em qualquer UPDATE.
--
-- Esta migração é aditiva: não altera 0001–0005.
-- =====================================================================

-- ------------------------------------------- 1. tira o UPDATE amplo
revoke update on public.usuarios, public.contas, public.cartoes,
                 public.categorias, public.lancamentos from authenticated;

-- --------------------------------- 2. devolve só as colunas funcionais
-- `email` e `parceiro_id` ficam de fora de propósito: o vínculo de casal
-- é responsabilidade de vincular_parceiro()/desvincular_parceiro(), que
-- são SECURITY DEFINER e seguem funcionando.
grant update (nome, renda_fixa_mensal)
  on public.usuarios to authenticated;

grant update (nome, saldo_atual, visibilidade, arquivada)
  on public.contas to authenticated;

grant update (nome, limite, dia_fechamento, dia_vencimento, visibilidade, arquivado)
  on public.cartoes to authenticated;

grant update (nome, classe_padrao, cor, arquivada)
  on public.categorias to authenticated;

grant update (tipo, valor, data, classe, categoria_id, descricao,
              conta_id, cartao_id, visibilidade, recorrente)
  on public.lancamentos to authenticated;

-- `atualizado_em` não é concedida a ninguém: quem a escreve é o gatilho
-- trg_atualizado_em, e gatilho não passa por verificação de privilégio de
-- coluna. O cliente não consegue forjá-la, e ela continua sendo mantida.

-- --------------------------- 3. defesa em profundidade: gatilho de posse
-- O privilégio por coluna já fecha o buraco. Este gatilho existe para o
-- caso de uma migração futura reconceder UPDATE amplo por engano — erro
-- fácil de cometer e silencioso de detectar.
--
-- Ele só barra o que vem direto do cliente: dentro de uma função
-- SECURITY DEFINER o current_user passa a ser o dono da função, então
-- caminhos privilegiados (as RPCs de vínculo, o provisionamento e uma
-- futura transferência de propriedade) continuam livres.
create or replace function app.congela_identidade()
returns trigger
language plpgsql
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  if new.id is distinct from old.id then
    raise exception 'id e imutavel' using errcode = '42501';
  end if;

  if new.criado_em is distinct from old.criado_em then
    raise exception 'criado_em e imutavel' using errcode = '42501';
  end if;

  if tg_table_name <> 'usuarios'
     and new.usuario_id is distinct from old.usuario_id then
    raise exception
      'usuario_id e imutavel: uma linha nao muda de dono pelo cliente'
      using errcode = '42501';
  end if;

  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['usuarios', 'contas', 'cartoes', 'categorias', 'lancamentos'] loop
    execute format('drop trigger if exists trg_congela_identidade on public.%I', t);
    execute format(
      'create trigger trg_congela_identidade before update on public.%I
         for each row execute function app.congela_identidade()', t);
  end loop;
end $$;
