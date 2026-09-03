# Assistente Financeiro de Recuperação

App pessoal de recuperação financeira para duas pessoas com **finanças separadas
e visão geral compartilhada**. PWA: roda no navegador do PC e instala na tela de
início do iPhone.

> Quanto posso gastar sem furar o plano, quando saio das dívidas e quanto
> consigo guardar.

**Estado:** Fase 1, etapas 1 e 2 concluídas — projeto, PWA, Supabase e o banco
com RLS. Cadastro, lançamento e dashboard são as próximas etapas.

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
| `./supabase/tests/run_local.sh` | Sobe um Postgres descartável, aplica as migrações e **testa o RLS** |

## Banco

As migrações estão em `supabase/migrations/`, para rodar em ordem (`0001` →
`0005`). Detalhes em [`supabase/README.md`](supabase/README.md).

Tabelas da Fase 1: `usuarios`, `contas`, `cartoes`, `categorias`, `lancamentos`.

## As três esferas de privacidade

Todo lançamento, conta e cartão nasce **privado**. O dono decide promover:

| Esfera | O parceiro vê | Como o banco garante |
|---|---|---|
| `privado` | nada | `usuario_id = auth.uid()` nas policies |
| `total_compartilhado` | **só o agregado** | a esfera está **ausente** do `USING` de todo `SELECT`; a soma sai de `resumo_do_parceiro()`, função `SECURITY DEFINER` que devolve `sum()` por classe/categoria e nunca um item |
| `casal` | detalhe completo, e edita | única esfera que atravessa, e só para parceiro **recíproco** |

O vínculo de casal só vale quando **os dois lados se apontam**. Sem isso,
escrever o id de alguém em `parceiro_id` não abre porta nenhuma — é o que o
teste cobre no caso do usuário C.

Rodando `./supabase/tests/run_local.sh`, 29 asserções verificam essas
fronteiras contra um Postgres real (inclusive as tentativas de escrita
indevida). Qualquer vazamento derruba o script.

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

## Próximas etapas (Fase 1)

3. Cadastro de contas, cartões e categorias personalizadas
4. Lançar receitas/gastos com classe, categoria, vínculo e visibilidade
5. Dashboard Resumo com 50/30/20 e sobra do mês

Fases 2 e 3 (dívidas, projeção, relatórios, motor de recomendação, visão do
casal, realtime) seguem a especificação.
