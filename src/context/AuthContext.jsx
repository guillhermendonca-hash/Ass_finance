import { useCallback, useEffect, useState } from 'react'
import { supabase, supabaseConfigurado } from '../lib/supabase'
import { AuthContext } from './contexto-auth'

export function AuthProvider({ children }) {
  const [sessao, setSessao] = useState(null)
  const [perfil, setPerfil] = useState(null)
  const [carregando, setCarregando] = useState(true)

  // O perfil vive em public.usuarios; a linha é criada pelo trigger
  // app.provisiona_usuario() no momento do cadastro.
  const carregarPerfil = useCallback(async (usuarioId) => {
    if (!usuarioId) return setPerfil(null)
    const { data, error } = await supabase
      .from('usuarios')
      .select('id, nome, email, renda_fixa_mensal, parceiro_id')
      .eq('id', usuarioId)
      .maybeSingle()
    if (error) console.error('Falha ao carregar perfil:', error.message)
    setPerfil(data ?? null)
  }, [])

  useEffect(() => {
    if (!supabaseConfigurado) return setCarregando(false)

    supabase.auth.getSession().then(({ data }) => {
      setSessao(data.session)
      carregarPerfil(data.session?.user?.id).finally(() => setCarregando(false))
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_evento, novaSessao) => {
      setSessao(novaSessao)
      carregarPerfil(novaSessao?.user?.id)
    })

    return () => sub.subscription.unsubscribe()
  }, [carregarPerfil])

  const entrar = (email, senha) =>
    supabase.auth.signInWithPassword({ email: email.trim(), password: senha })

  const cadastrar = (email, senha, nome) =>
    supabase.auth.signUp({
      email: email.trim(),
      password: senha,
      options: { data: { nome: nome.trim() } },
    })

  const sair = () => supabase.auth.signOut()

  return (
    <AuthContext.Provider
      value={{
        sessao,
        usuario: sessao?.user ?? null,
        perfil,
        carregando,
        entrar,
        cadastrar,
        sair,
        recarregarPerfil: () => carregarPerfil(sessao?.user?.id),
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}
