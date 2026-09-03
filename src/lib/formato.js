const moedaBRL = new Intl.NumberFormat('pt-BR', {
  style: 'currency',
  currency: 'BRL',
})

export const moeda = (valor) => moedaBRL.format(Number(valor) || 0)

export const dataCurta = (iso) =>
  new Date(iso + 'T12:00:00').toLocaleDateString('pt-BR', {
    day: '2-digit',
    month: 'short',
  })

/** Primeiro e último dia do mês de referência, no formato aceito pelo Postgres. */
export function intervaloDoMes(referencia = new Date()) {
  const ano = referencia.getFullYear()
  const mes = referencia.getMonth()
  const iso = (d) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
      d.getDate(),
    ).padStart(2, '0')}`
  return { inicio: iso(new Date(ano, mes, 1)), fim: iso(new Date(ano, mes + 1, 0)) }
}
