import { useCallback, useEffect, useMemo, useState } from 'react'
import { DadosContext } from './dados-contexto'
import { useAuth } from './useAuth'
import * as api from '../lib/api'

const VAZIO = { contas: [], cartoes: [], categorias: [], lancamentos: [] }

export function DadosProvider({ children }) {
  const { usuario, recarregarPerfil } = useAuth()
  const [dados, setDados] = useState(VAZIO)
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState('')

  const recarregar = useCallback(async () => {
    if (!usuario) return setDados(VAZIO)
    try {
      setDados(await api.carregarTudo())
      setErro('')
    } catch (e) {
      setErro(api.mensagemDeErro(e))
    }
  }, [usuario])

  useEffect(() => {
    setCarregando(true)
    recarregar().finally(() => setCarregando(false))
  }, [recarregar])

  // Toda gravação recarrega: um lançamento mexe no saldo da conta pelo
  // gatilho do banco, e a tela precisa ver o número novo.
  const gravar = useCallback(
    async (executar) => {
      const { error } = await executar()
      if (error) return { erro: api.mensagemDeErro(error) }
      await recarregar()
      return { erro: '' }
    },
    [recarregar],
  )

  const valor = useMemo(
    () => ({
      ...dados,
      carregando,
      erro,
      recarregar,
      criar: (tabela, campos) => gravar(() => api.inserir(tabela, usuario.id, campos)),
      editar: (tabela, id, campos) => gravar(() => api.atualizar(tabela, id, campos)),
      apagar: (tabela, id) => gravar(() => api.remover(tabela, id)),
      salvarPerfil: async (campos) => {
        const { error } = await api.salvarPerfil(usuario.id, campos)
        if (error) return { erro: api.mensagemDeErro(error) }
        await recarregarPerfil()
        return { erro: '' }
      },
    }),
    [dados, carregando, erro, recarregar, gravar, usuario, recarregarPerfil],
  )

  return <DadosContext.Provider value={valor}>{children}</DadosContext.Provider>
}
