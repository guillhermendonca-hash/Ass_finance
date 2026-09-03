import { useState } from 'react'
import { useAuth } from '../context/useAuth'

export default function Login() {
  const { entrar, cadastrar } = useAuth()
  const [modo, setModo] = useState('entrar')
  const [nome, setNome] = useState('')
  const [email, setEmail] = useState('')
  const [senha, setSenha] = useState('')
  const [erro, setErro] = useState('')
  const [aviso, setAviso] = useState('')
  const [enviando, setEnviando] = useState(false)

  const criandoConta = modo === 'cadastrar'

  async function aoEnviar(evento) {
    evento.preventDefault()
    setErro('')
    setAviso('')
    setEnviando(true)

    const { data, error } = criandoConta
      ? await cadastrar(email, senha, nome)
      : await entrar(email, senha)

    setEnviando(false)

    if (error) return setErro(traduzErro(error.message))

    // Com confirmação de e-mail ligada no Supabase, não vem sessão na hora.
    if (criandoConta && !data.session) {
      setAviso('Conta criada. Confirme o e-mail que acabamos de enviar para entrar.')
    }
  }

  return (
    <div className="entrada">
      <div className="entrada__marca">Assistente Financeiro</div>
      <p className="entrada__frase">
        Quanto posso gastar sem furar o plano, quando saio das dívidas e quanto
        consigo guardar.
      </p>

      {erro && <div className="aviso aviso--erro">{erro}</div>}
      {aviso && <div className="aviso aviso--sucesso">{aviso}</div>}

      <form onSubmit={aoEnviar}>
        {criandoConta && (
          <label className="campo">
            <span className="campo__rotulo">Nome</span>
            <input
              type="text"
              value={nome}
              onChange={(e) => setNome(e.target.value)}
              autoComplete="name"
              required
            />
          </label>
        )}

        <label className="campo">
          <span className="campo__rotulo">E-mail</span>
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
            required
          />
        </label>

        <label className="campo">
          <span className="campo__rotulo">Senha</span>
          <input
            type="password"
            value={senha}
            onChange={(e) => setSenha(e.target.value)}
            autoComplete={criandoConta ? 'new-password' : 'current-password'}
            minLength={6}
            required
          />
        </label>

        <button className="botao" type="submit" disabled={enviando}>
          {enviando ? 'Um instante…' : criandoConta ? 'Criar conta' : 'Entrar'}
        </button>
      </form>

      <button
        type="button"
        className="botao botao--texto"
        onClick={() => {
          setModo(criandoConta ? 'entrar' : 'cadastrar')
          setErro('')
          setAviso('')
        }}
      >
        {criandoConta ? 'Já tenho conta' : 'Criar uma conta'}
      </button>

      <p className="rodape-nota">
        Todo lançamento nasce privado. Você decide o que o outro vê.
      </p>
    </div>
  )
}

function traduzErro(mensagem) {
  const mapa = {
    'Invalid login credentials': 'E-mail ou senha incorretos.',
    'Email not confirmed': 'Confirme o e-mail antes de entrar.',
    'User already registered': 'Esse e-mail já tem conta. Tente entrar.',
    'Password should be at least 6 characters.':
      'A senha precisa de pelo menos 6 caracteres.',
  }
  return mapa[mensagem] ?? mensagem
}
