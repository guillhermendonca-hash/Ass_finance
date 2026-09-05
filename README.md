# Assistente Financeiro de Recuperação

App pessoal de recuperação financeira para duas pessoas com **finanças separadas
e visão geral compartilhada**. PWA: roda no navegador do PC e instala na tela de
início do iPhone.

> Quanto posso gastar sem furar o plano, quando saio das dívidas e quanto
> consigo guardar.

**Estado:** Fase 1 completa — projeto, PWA, Supabase, banco com RLS, cadastro
de contas/cartões/categorias, lançamento e o dashboard com 50/30/20. A Fase 2
(dívidas, projeção, relatórios, motor de recomendação) ainda não começou.

## Rodar

```bash
npm install
cp .env.example .env      # preencha com os dados do seu projeto Supabase
npm run dev
```

Sem o `.env` o app sobe assim mesmo e mostra na tela o que falta configurar.

| Comando | O que faz |
|---|---|
| `npm run dev` | Servidor de desenvolvimento |
| `npm run build` | Build de produção + service worker |
| `npm run preview` | Serve o build localmente |
| `npm run lint` | ESLint |
| `npm test` | Testes da lógica pura (50/30/20, fatura, leitura de valores) |
| `./supabase/tests/run_local.sh` | Sobe um Postgres descartável, aplica as migrações e **testa o RLS** |
| `./supabase/tests/run_households_backfill.sh` | Testa o **upgrade**: dados primeiro, `0008` depois |

## Banco

As migrações estão em `supabase/migrations/`, para rodar em ordem (`0001` →
`0009`). Detalhes em [`supabase/README.md`](supabase/README.md).

Tabelas da Fase 1: `usuarios`, `contas`, `cartoes`, `categorias`, `lancamentos`.

## As três esferas de privacidade

Todo lançamento, conta e cartão nasce **privado**. O dono decide promover:

| Esfera | O parceiro vê | Como o banco garante |
|---|---|---|
| `privado` | nada | `usuario_id = auth.uid()` nas policies |
| `total_compartilhado` | **só o agregado** | a esfera está **ausente** do `USING` de todo `SELECT`; a soma sai de `resumo_do_parceiro()`, função `SECURITY DEFINER` que devolve `sum()` por classe/categoria e nunca um item |
| `casal` | detalhe completo, e edita | única esfera que atravessa, e só para parceiro **recíproco** |

O vínculo de casal vive numa **membresia**: as duas pessoas precisam estar no
mesmo *household*. `parceiro_id` sobrou apenas como registro da solicitação —
escrever o id de alguém lá não abre porta nenhuma, nem mesmo se o outro lado
apontar de volta sem que a RPC tenha rodado. É o que o teste cobre nos casos do
usuário C e do ponteiro obsoleto.

Declarar é uma coisa, confirmar é outra: `vincular_parceiro` grava a solicitação
e para por aí. Só quando o outro lado confirma é que os dois *households*
individuais se fundem e os dados passam a ser vistos.

Rodando `./supabase/tests/run_local.sh`, 123 asserções verificam essas
fronteiras contra um Postgres real (inclusive as tentativas de escrita
indevida). Qualquer vazamento derruba o script.

**Uma linha nunca muda de dono pelo cliente.** RLS decide quais *linhas* o
cliente alcança; ela não decide quais *colunas*. Sem isso, o parceiro com
acesso a uma linha `casal` podia trocar `usuario_id` e `visibilidade` na mesma
instrução e se apropriar dela. A migração `0006` revoga o `UPDATE` de tabela
inteira e concede apenas as colunas funcionais — `usuario_id`, `id`,
`criado_em` e `atualizado_em` deixam de ser endereçáveis.

## Stack

React + Vite · `vite-plugin-pwa` · Supabase (Postgres + Auth) · CSS puro.

Identidade: Playfair Display + bordeaux `#7B1D2E` sobre off-white `#FBF7F4`,
mobile-first com navegação inferior fixa.

## Estrutura

```
src/
  lib/supabase.js         cliente; avisa em vez de quebrar se faltar .env
  context/                sessão e perfil do usuário
  components/             layout, navegação inferior
  pages/                  Resumo · Lançar · Carteira · Dívidas · Ajustes
supabase/
  migrations/             esquema, RLS e API de privacidade
  tests/                  teste das fronteiras + Postgres descartável
```

## O que as telas fazem hoje

- **Resumo** — saldo em contas, sobra do mês, diagnóstico 50/30/20 com a meta
  marcada em cada barra, e a fatura aberta de cada cartão com a barra de limite
  (vermelha acima de 80%).
- **Lançar** — gasto ou recebimento com valor, classe, categoria, vínculo a
  conta ou cartão, data, visibilidade e descrição. Escolher a categoria já
  ajusta a classe. Lista dos últimos lançamentos, com excluir.
- **Carteira** — contas (saldo, visibilidade) e cartões (limite, fechamento,
  vencimento, fatura do ciclo aberto).
- **Ajustes** — nome, renda fixa mensal e as categorias personalizadas.
- **Dívidas** — Fase 2.

O saldo da conta é ajustado pelo banco, não pelo app: um gatilho em
`lancamentos` move `contas.saldo_atual` a cada inserção, edição e exclusão.

## Próximas etapas (Fase 2)

6. Módulo de dívidas (rotativa + parcelamento), ordem de ataque, projeção
7. Calendário de parcelas futuras
8. Reserva de emergência em duas fases
9. Orçamentos por categoria com os três alertas
10. Relatórios (pizza, comparativo 6 meses, evolução da dívida)
11. Motor de recomendação ativa
