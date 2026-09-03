import { cicloFatura } from './periodo.js'

/**
 * Fatura ainda aberta de um cartão: o que foi gasto dentro do ciclo que
 * ainda não fechou. `uso` alimenta a barra de limite do resumo.
 */
export function faturaAberta(cartao, lancamentos, hoje = new Date()) {
  const { inicio, fim } = cicloFatura(cartao.dia_fechamento, hoje)
  const itens = lancamentos.filter(
    (l) => l.cartao_id === cartao.id && l.tipo === 'gasto' && l.data >= inicio && l.data <= fim,
  )
  const total = itens.reduce((t, l) => t + Number(l.valor), 0)
  const limite = Number(cartao.limite) || 0
  return { inicio, fim, total, quantidade: itens.length, uso: limite > 0 ? total / limite : 0 }
}

/**
 * 50/30/20 adaptado (seção 7): 50% essenciais, 30% variáveis, 20% para
 * dívidas e reserva. Na recuperação os 20% priorizam dívida, depois da
 * reserva mínima — mas isso é decisão da Fase 2; aqui só medimos.
 */
export const ALVOS = { essencial: 0.5, variavel: 0.3, sobra: 0.2 }

const somar = (itens) => itens.reduce((t, l) => t + Number(l.valor), 0)

export function diagnostico(lancamentos, rendaFixaMensal = 0) {
  const receitas = somar(lancamentos.filter((l) => l.tipo === 'receita'))
  const essenciais = somar(lancamentos.filter((l) => l.classe === 'essencial'))
  const variaveis = somar(lancamentos.filter((l) => l.classe === 'variavel'))

  // A renda declarada manda. Sem ela, as receitas lançadas no mês servem de
  // base — some as duas e um salário lançado contaria duas vezes.
  const renda = Number(rendaFixaMensal) || 0
  const base = renda > 0 ? renda : receitas
  const sobra = base - essenciais - variaveis

  const fatia = (valor) => (base > 0 ? valor / base : 0)

  return {
    base,
    baseVemDosLancamentos: renda <= 0,
    receitas,
    essenciais,
    variaveis,
    gastos: essenciais + variaveis,
    sobra,
    faixas: [
      { chave: 'essencial', rotulo: 'Essenciais', valor: essenciais, fatia: fatia(essenciais), alvo: ALVOS.essencial },
      { chave: 'variavel', rotulo: 'Variáveis', valor: variaveis, fatia: fatia(variaveis), alvo: ALVOS.variavel },
      { chave: 'sobra', rotulo: 'Sobra', valor: sobra, fatia: fatia(sobra), alvo: ALVOS.sobra },
    ],
  }
}
