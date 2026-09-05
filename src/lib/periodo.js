/** Datas no formato que o Postgres aceita em coluna `date`. */
export const iso = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`

/** Dia 31 em fevereiro não existe: encolhe para o último dia do mês. */
function diaQueExiste(ano, mes, dia) {
  const ultimo = new Date(ano, mes + 1, 0).getDate()
  return Math.min(dia, ultimo)
}

export function intervaloDoMes(referencia = new Date()) {
  const ano = referencia.getFullYear()
  const mes = referencia.getMonth()
  return { inicio: iso(new Date(ano, mes, 1)), fim: iso(new Date(ano, mes + 1, 0)) }
}

/** Primeiro dia do mês anterior — janela que a tela de lançar usa. */
export function inicioDoMesAnterior(referencia = new Date()) {
  return iso(new Date(referencia.getFullYear(), referencia.getMonth() - 1, 1))
}

export function nomeDoMes(referencia = new Date()) {
  return referencia.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' })
}

/**
 * Janela da fatura ainda aberta de um cartão.
 *
 * A compra entra na fatura que fecha depois dela. Com fechamento no dia 10,
 * uma compra em 11/03 cai na fatura que fecha em 10/04; uma em 09/03 cai na
 * que fecha em 10/03. O dia do fechamento pertence à fatura que fecha nele.
 */
export function cicloFatura(diaFechamento, hoje = new Date()) {
  const ano = hoje.getFullYear()
  const mes = hoje.getMonth()
  // zera a hora: às 14h do dia do fechamento a fatura ainda é a que fecha hoje
  const agora = new Date(ano, mes, hoje.getDate())
  const fechaEsteMes = new Date(ano, mes, diaQueExiste(ano, mes, diaFechamento))
  const jaFechou = agora > fechaEsteMes

  const fim = jaFechou
    ? new Date(ano, mes + 1, diaQueExiste(ano, mes + 1, diaFechamento))
    : fechaEsteMes
  const anterior = jaFechou
    ? fechaEsteMes
    : new Date(ano, mes - 1, diaQueExiste(ano, mes - 1, diaFechamento))

  const inicio = new Date(anterior)
  inicio.setDate(inicio.getDate() + 1)
  return { inicio: iso(inicio), fim: iso(fim) }
}
