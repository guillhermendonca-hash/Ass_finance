import { test } from 'node:test'
import assert from 'node:assert/strict'
import { paraNumero } from './formato.js'

test('lê valor no formato brasileiro', () => {
  assert.equal(paraNumero('1.234,56'), 1234.56)
  assert.equal(paraNumero('89,90'), 89.9)
})

test('aceita também o ponto decimal', () => {
  assert.equal(paraNumero('1234.56'), 1234.56)
  assert.equal(paraNumero('42'), 42)
})

test('texto vazio ou inválido vira zero, não NaN', () => {
  for (const entrada of ['', '   ', 'abc', null, undefined]) {
    assert.equal(paraNumero(entrada), 0)
  }
})
