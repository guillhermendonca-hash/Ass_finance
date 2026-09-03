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


/**
 * Lê valor digitado em português: "1.234,56" e "1234.56" viram 1234.56.
 * A vírgula decide: com ela, o ponto é separador de milhar.
 */
export function paraNumero(texto) {
  const t = String(texto ?? '').trim()
  if (!t) return 0
  const normalizado = t.includes(',') ? t.replace(/\./g, '').replace(',', '.') : t
  const n = Number(normalizado)
  return Number.isFinite(n) ? n : 0
}
