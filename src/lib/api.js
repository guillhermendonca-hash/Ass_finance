import { supabase } from './supabase'
import { inicioDoMesAnterior } from './periodo.js'

/** Traduz o que o Postgres devolve para algo que se lê na tela. */
export function mensagemDeErro(erro) {
  if (!erro) return ''
  if (erro.code === '23505') return 'Já existe um registro com esse nome.'
  if (erro.code === '23514') return erro.message.replace(/^.*?:\s*/, '')
  if (erro.code === '42501')
    return 'Esse registro não é seu — o banco recusou a alteração.'
  return erro.message ?? 'Algo deu errado.'
}

function garantir({ data, error }) {
  if (error) throw error
  return data
}

/**
 * Carrega tudo de uma vez. O conjunto é pequeno (duas pessoas, um par de
 * meses) e recarregar inteiro depois de cada gravação evita estado velho —
 * o saldo da conta, por exemplo, muda no banco quando um lançamento entra.
 */
export async function carregarTudo() {
  const desde = inicioDoMesAnterior()

  const [contas, cartoes, categorias, lancamentos] = await Promise.all([
    supabase.from('contas').select('*').eq('arquivada', false).order('nome'),
    supabase.from('cartoes').select('*').eq('arquivado', false).order('nome'),
    supabase.from('categorias').select('*').eq('arquivada', false).order('nome'),
    supabase
      .from('lancamentos')
      .select('*')
      .gte('data', desde)
      .order('data', { ascending: false })
      .order('criado_em', { ascending: false }),
  ])

  return {
    contas: garantir(contas),
    cartoes: garantir(cartoes),
    categorias: garantir(categorias),
    lancamentos: garantir(lancamentos),
  }
}

export const inserir = (tabela, usuarioId, dados) =>
  supabase.from(tabela).insert({ ...dados, usuario_id: usuarioId }).select().single()

export const atualizar = (tabela, id, dados) =>
  supabase.from(tabela).update(dados).eq('id', id).select().single()

export const remover = (tabela, id) => supabase.from(tabela).delete().eq('id', id)

export const salvarPerfil = (usuarioId, dados) =>
  supabase.from('usuarios').update(dados).eq('id', usuarioId).select().single()
