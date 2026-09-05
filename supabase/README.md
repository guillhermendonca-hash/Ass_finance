# Banco (Supabase)

## Aplicar as migrações

Migrações versionadas são aplicadas **pelo Supabase CLI**, e apenas dentro de
uma janela de deploy explicitamente autorizada:

```bash
supabase link --project-ref SEU_REF
supabase db push
```

Não cole migração no SQL Editor do painel. O `db push` mantém o histórico de
migrações do projeto e aplica cada arquivo na fronteira transacional certa; a
execução manual não faz nem uma coisa nem outra, e deixa o histórico mentindo
sobre o que está aplicado.

> **A `0008` não pode ser implantada isoladamente.** O backfill fotografa
> `parceiro_id` no momento em que roda; vínculos criados ou desfeitos depois
> divergem. Não há deploy intermediário entre a fatia B1 e a B2.

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
| `0008_households_fundacao.sql` | **Fundação transicional de households** — sombra, ver aviso abaixo |

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
transação e dá `rollback` no fim — não deixa resíduo no banco. São 80
asserções, e cada ataque confere também o **estado final da linha**: capturar
a exceção não basta.

Para escolher **onde** o cluster descartável é criado:

```bash
PGTEST_PARENT=/caminho/pai ./supabase/tests/run_local.sh
```

`PGTEST_PARENT` é só o diretório **pai**. O runner cria dentro dele um
subdiretório próprio (`ass-finance-pgtest.XXXXXX`), grava ali um marcador de
posse com um valor desta execução, e no fim remove **apenas esse filho** — nunca
o pai, nunca nada que já estivesse lá. Se, na hora de limpar, o caminho não
casar mais com pai+prefixo ou o marcador não bater, a remoção é recusada e o
diretório fica preservado, com aviso.

O pai precisa existir, ser diretório e ser caminho absoluto; caminho relativo,
inexistente ou apontando para arquivo é recusado antes de qualquer coisa ser
criada. Rodando como root, o pai também precisa ser atravessável pelo usuário
`postgres` (`chmod o+x`), e o runner diz isso em vez de falhar no meio.

### O segundo arnês: upgrade

`run_local.sh` aplica todas as migrações **antes** de existir qualquer usuário,
então o backfill da `0008` nunca roda ali. Para exercitar a ordem real de um
upgrade — dados primeiro, migração depois — existe um segundo arnês:

```bash
PGTEST_PARENT=/caminho/pai ./supabase/tests/run_households_backfill.sh
```

Ele aplica `0001`–`0007`, cria um par recíproco, um vínculo unilateral e um
usuário isolado com entidades de cada tipo — e então faz duas coisas.

**Primeiro prova que a `0008` é atômica.** Instala um gatilho que derruba a
migração no meio do backfill, num ponto em que ela já criou tabelas, adicionou
colunas e desabilitou os quatro `trg_atualizado_em`. Exige que a migração falhe,
e verifica que o rollback não deixou resíduo nenhum — inclusive que os carimbos
voltaram a existir **e a estar habilitados**. São 8 asserções.

**Depois aplica a `0008` de verdade** e verifica o agrupamento: mais 23
asserções. Total de 31.

Isso funciona porque cada migração roda com `psql -1`, ou seja, o arquivo
inteiro é uma única transação. Sem isso, uma falha no meio deixaria DDL aplicada
e gatilhos desligados. Os arquivos de teste, ao contrário, rodam sem `-1`,
porque administram a própria transação.

## Households (fundação transicional)

> **Não implantar a `0008` sozinha.** O backfill fotografa `parceiro_id` no
> momento em que a migração roda. Vínculos criados ou desfeitos depois disso
> não são refletidos: a sombra diverge. Não pode haver deploy entre esta fatia
> e a que faz o cutover.

`households` e `household_members` existem, são preenchidas a partir de
`parceiro_id` e recebem toda entidade nova por derivação — mas **nada** no
comportamento observável muda ainda. `parceiro_id`, os helpers, as RPCs e as
policies continuam sendo a autoridade.

O teto de dois membros não vem de gatilho com `count(*)` — que duas transações
simultâneas furariam — e sim de `posicao smallint check (posicao in (1,2))` mais
um índice único em `(household_id, posicao)`. Um índice único em `usuario_id`
garante uma membresia por pessoa.

O cliente não alcança a sombra: RLS ligada, nenhuma policy, e todo privilégio
revogado de `PUBLIC`, `anon` e `authenticated`. `household_id` é sempre derivado
de `usuario_id` por gatilho — payload omitido recebe o valor certo, payload
forjado é sobrescrito — e não entra nos grants de `UPDATE` da `0006`.

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
