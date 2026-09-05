import { useContext } from 'react'
import { DadosContext } from './dados-contexto'

export function useDados() {
  const ctx = useContext(DadosContext)
  if (!ctx) throw new Error('useDados precisa estar dentro de <DadosProvider>')
  return ctx
}
