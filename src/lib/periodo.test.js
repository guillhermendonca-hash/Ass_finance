import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cicloFatura, intervaloDoMes, inicioDoMesAnterior } from './periodo.js'

test('a compra depois do fechamento cai na fatura seguinte', () => {
  assert.deepEqual(cicloFatura(10, new Date(2026, 2, 15)), {
    inicio: '2026-03-11',
    fim: '2026-04-10',
  })
})

test('a compra antes do fechamento cai na fatura que fecha neste mês', () => {
  assert.deepEqual(cicloFatura(10, new Date(2026, 2, 5)), {
    inicio: '2026-02-11',
    fim: '2026-03-10',
  })
})

test('o dia do fechamento pertence à fatura que fecha nele', () => {
  assert.deepEqual(cicloFatura(10, new Date(2026, 2, 10, 14, 30)), {
    inicio: '2026-02-11',
    fim: '2026-03-10',
  })
})

test('fechamento no dia 31 encolhe para o último dia de fevereiro', () => {
  assert.deepEqual(cicloFatura(31, new Date(2026, 1, 15)), {
    inicio: '2026-02-01',
    fim: '2026-02-28',
  })
})

test('fechamento no dia 31 volta a 31 no mês seguinte', () => {
  assert.deepEqual(cicloFatura(31, new Date(2026, 2, 1)), {
    inicio: '2026-03-01',
    fim: '2026-03-31',
  })
})

test('a fatura atravessa a virada do ano', () => {
  assert.deepEqual(cicloFatura(10, new Date(2026, 0, 5)), {
    inicio: '2025-12-11',
    fim: '2026-01-10',
  })
  assert.deepEqual(cicloFatura(10, new Date(2025, 11, 15)), {
    inicio: '2025-12-11',
    fim: '2026-01-10',
  })
})

test('o intervalo do mês vai do dia 1 ao último', () => {
  assert.deepEqual(intervaloDoMes(new Date(2026, 1, 9)), {
    inicio: '2026-02-01',
    fim: '2026-02-28',
  })
  assert.equal(inicioDoMesAnterior(new Date(2026, 0, 9)), '2025-12-01')
})
