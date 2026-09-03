# Banco (Supabase)

## Aplicar as migrações

Pelo painel: **SQL Editor → New query**, cole e rode cada arquivo de
`migrations/` **na ordem numérica** (0001 → 0005).

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

O script cria dois usuários fictícios, vincula os dois, e falha com erro se
qualquer uma das fronteiras vazar. Ele roda dentro de uma transação e dá
`rollback` no fim — não deixa resíduo no banco.

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
