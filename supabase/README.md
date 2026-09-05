# Banco (Supabase)

## Aplicar as migrações

Pelo painel: **SQL Editor → New query**, cole e rode cada arquivo de
`migrations/` **na ordem numérica** (0001 → 0007).

Pela CLI:

```bash
supabase link --project-ref SEU_REF
supabase db push
```

## O que cada arquivo faz

| Arquivo | Conteúdo |
|---|---|
| `0001_schema.sql` | Tipos, as 5 tabelas da Fase 1, índices, `atualizado_em` |
| `0002_regras_integridade.sql` | Parceria recíproca, validação de vínculos, saldo automático da conta |
| `0003_rls.sql` | **Row Level Security — as três esferas de privacidade** |
| `0004_api_privacidade.sql` | Agregados do parceiro (somar sem vazar o item) e vínculo de casal |
| `0005_novo_usuario.sql` | Cria `usuarios` e semeia categorias no cadastro |
| `0006_restringe_colunas_editaveis.sql` | **Privilégio de `UPDATE` por coluna**: a linha não muda de dono pelo cliente |
| `0007_corrige_gatilho_identidade_usuario.sql` | Gatilho de identidade próprio para `usuarios`, que não tem `usuario_id` |

## As três esferas, em uma frase cada

- **`privado`** (padrão de tudo): `usuario_id = auth.uid()`. Ninguém mais lê.
- **`total_compartilhado`**: a linha **não** aparece no `USING` de nenhuma policy
  de `SELECT` do parceiro. Ele só alcança o dado por `resumo_do_parceiro()`,
  que devolve `sum()` agrupado por classe/categoria.
- **`casal`**: atravessa para o parceiro **confirmado** (vínculo recíproco), com
  detalhe completo e permissão de editar.

## Como conferir que o RLS está de pé

```bash
psql "$DATABASE_URL" -f tests/rls_test.sql
```

O script cria três usuários fictícios (dois vinculados, um com vínculo
unilateral) e falha com erro se qualquer fronteira vazar. Roda dentro de uma
transação e dá `rollback` no fim — não deixa resíduo no banco. São 50
asserções, e cada ataque confere também o **estado final da linha**: capturar
a exceção não basta.

Para escolher onde o cluster descartável é criado:

```bash
PGTEST_DIR=$(mktemp -d) ./supabase/tests/run_local.sh
```

## Posse da linha

RLS decide quais **linhas** o cliente alcança; ela não decide quais
**colunas**. As policies de `UPDATE` avaliam o `USING` na linha antiga e o
`WITH CHECK` na linha nova, então um parceiro com acesso a uma linha `casal`
podia executar `set usuario_id = <ele>, visibilidade = 'privado'` e passar nos
dois: o `USING` via a linha antiga (casal, de um parceiro recíproco) e o
`WITH CHECK` via a linha nova (dele).

A migração `0006` fecha isso com privilégio por coluna: `revoke update` da
tabela inteira e `grant update (colunas funcionais)`. `usuario_id`, `id`,
`criado_em` e `atualizado_em` deixam de ser endereçáveis em qualquer `UPDATE`
do cliente, e `usuarios.email`/`usuarios.parceiro_id` também — o vínculo
continua sendo responsabilidade das RPCs `SECURITY DEFINER`.

Há ainda um gatilho `trg_congela_identidade` como defesa em profundidade, para
o caso de uma migração futura reconceder `UPDATE` amplo por engano. Ele só
barra o que vem direto do cliente: dentro de uma função `SECURITY DEFINER` o
`current_user` é o dono da função, então caminhos privilegiados seguem livres.

`usuarios` usa uma função de gatilho separada, `app.congela_identidade_usuario()`
(migração `0007`), porque essa tabela não tem `usuario_id`. A função da `0006`
acessava esse campo atrás de uma condição `tg_table_name <> 'usuarios'`, e o
plpgsql **não** faz curto-circuito ali — a expressão inteira é avaliada como uma
só, o campo é resolvido de qualquer forma, e todo `UPDATE` de perfil pelo cliente
morria com `record "new" has no field "usuario_id"`.

## Nota honesta sobre o agregado

Se uma categoria `total_compartilhado` tem **um único** lançamento no mês, a
soma daquela categoria *é* o valor daquele lançamento. Isso é inerente ao que a
seção 3 pede (somar por categoria). Por isso `resumo_do_parceiro()` devolve
também `quantidade`: a interface consegue avisar o dono de que aquela linha
está praticamente exposta, e ele decide se mantém compartilhada.

## Realtime (Fase 3)

Quando chegar a hora, basta:

```sql
alter publication supabase_realtime add table public.lancamentos, public.contas, public.cartoes;
```

O RLS continua valendo nas mensagens de realtime — o parceiro não recebe evento
de linha que não pode ler.
