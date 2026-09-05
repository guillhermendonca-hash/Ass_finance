import { test } from 'node:test'
import assert from 'node:assert/strict'
import { diagnostico, faturaAberta } from './diagnostico.js'

const gasto = (valor, classe) => ({ tipo: 'gasto', classe, valor })
const receita = (valor) => ({ tipo: 'receita', classe: 'receita', valor })

test('reparte a renda declarada entre essenciais, variáveis e sobra', () => {
  const d = diagnostico([gasto(2000, 'essencial'), gasto(1000, 'variavel')], 5000)
  assert.equal(d.base, 5000)
  assert.equal(d.essenciais, 2000)
  assert.equal(d.variaveis, 1000)
  assert.equal(d.sobra, 2000)
  assert.deepEqual(
    d.faixas.map((f) => f.fatia),
    [0.4, 0.2, 0.4],
  )
})

test('sem renda declarada, as receitas do mês viram a base', () => {
  const d = diagnostico([receita(3000), gasto(900, 'essencial')], 0)
  assert.equal(d.base, 3000)
  assert.equal(d.baseVemDosLancamentos, true)
  assert.equal(d.sobra, 2100)
})

test('a renda declarada não soma com as receitas lançadas', () => {
  // salário de 5000 declarado E lançado: a base continua 5000, não 10000
  const d = diagnostico([receita(5000), gasto(1000, 'variavel')], 5000)
  assert.equal(d.base, 5000)
  assert.equal(d.receitas, 5000)
})

test('gastar mais do que entra deixa a sobra negativa', () => {
  const d = diagnostico([gasto(3000, 'essencial'), gasto(1500, 'variavel')], 4000)
  assert.equal(d.sobra, -500)
  assert.ok(d.faixas[2].fatia < 0)
})

test('sem base nenhuma, as fatias ficam em zero e não viram NaN', () => {
  const d = diagnostico([gasto(120, 'variavel')], 0)
  assert.equal(d.base, 0)
  assert.ok(d.faixas.every((f) => Number.isFinite(f.fatia) && f.fatia === 0))
})

test('lista vazia não quebra', () => {
  const d = diagnostico([], 0)
  assert.equal(d.sobra, 0)
  assert.equal(d.gastos, 0)
})

test('a fatura aberta soma só o que caiu no ciclo que ainda não fechou', () => {
  const cartao = { id: 'c1', dia_fechamento: 10, limite: 2000 }
  const lancamentos = [
    { cartao_id: 'c1', tipo: 'gasto', valor: 300, data: '2026-03-12' }, // dentro
    { cartao_id: 'c1', tipo: 'gasto', valor: 500, data: '2026-04-10' }, // dia do fechamento: dentro
    { cartao_id: 'c1', tipo: 'gasto', valor: 900, data: '2026-03-09' }, // fatura anterior
    { cartao_id: 'c2', tipo: 'gasto', valor: 700, data: '2026-03-15' }, // outro cartão
  ]
  const f = faturaAberta(cartao, lancamentos, new Date(2026, 2, 20))
  assert.equal(f.total, 800)
  assert.equal(f.quantidade, 2)
  assert.equal(f.uso, 0.4)
})

test('cartão sem limite não divide por zero', () => {
  const f = faturaAberta({ id: 'c1', dia_fechamento: 5, limite: 0 }, [], new Date(2026, 2, 20))
  assert.equal(f.uso, 0)
})
