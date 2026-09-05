import { useState } from 'react'
import { useAuth } from '../context/useAuth'
import { useDados } from '../context/useDados'
import { moeda, paraNumero } from '../lib/formato'
import Folha from '../components/Folha'

const CLASSES = [
  { valor: 'essencial', rotulo: 'Essencial' },
  { valor: 'variavel', rotulo: 'Variável' },
  { valor: 'receita', rotulo: 'Receita' },
]

export default function Ajustes() {
  const { usuario, perfil, sair } = useAuth()
  const { categorias, salvarPerfil } = useDados()
  const [editando, setEditando] = useState(null)

  return (
    <>
      <header className="cabecalho">
        <h1>Ajustes</h1>
      </header>

      <FormularioPerfil perfil={perfil} email={usuario?.email} aoSalvar={salvarPerfil} />

      <div className="cartao">
        <div className="cartao__rotulo">Categorias</div>
        {categorias.map((c) => (
          <div
            key={c.id}
            className="item item--clicavel"
            onClick={() => setEditando({ registro: c })}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => e.key === 'Enter' && setEditando({ registro: c })}
          >
            <span className="item__nome">
              <span className="ponto-cor" style={{ background: c.cor }} />
              {c.nome}
            </span>
            <span className="faixa__meta">
              {CLASSES.find((k) => k.valor === c.classe_padrao)?.rotulo}
            </span>
          </div>
        ))}
        <button
          className="botao botao--secundario"
          style={{ marginTop: 14 }}
          onClick={() => setEditando({ registro: null })}
        >
          Nova categoria
        </button>
      </div>

      <div className="cartao">
        <div className="cartao__rotulo">Instalar no iPhone</div>
        <ol className="lista-checagem">
          <li>Abra este endereço no Safari.</li>
          <li>Toque em Compartilhar.</li>
          <li>Escolha “Adicionar à Tela de Início”.</li>
        </ol>
      </div>

      <div className="cartao">
        <div className="cartao__rotulo">Ainda não construído</div>
        <p style={{ color: 'var(--texto-suave)', fontSize: 14, margin: '4px 0 0' }}>
          Vínculo com a parceira e exportação do backup em JSON entram na Fase 3.
          O banco já tem o vínculo pronto, com as três esferas de privacidade.
        </p>
      </div>

      <button className="botao botao--texto" onClick={sair} style={{ marginTop: 18 }}>
        Sair da conta
      </button>

      {editando && (
        <FormularioCategoria registro={editando.registro} aoFechar={() => setEditando(null)} />
      )}
    </>
  )
}

function FormularioPerfil({ perfil, email, aoSalvar }) {
  const [nome, setNome] = useState(perfil?.nome ?? '')
  const [renda, setRenda] = useState(
    perfil?.renda_fixa_mensal ? String(perfil.renda_fixa_mensal) : '',
  )
  const [estado, setEstado] = useState({ erro: '', salvo: false })
  const [ocupado, setOcupado] = useState(false)

  async function enviar(evento) {
    evento.preventDefault()
    setOcupado(true)
    const { erro } = await aoSalvar({
      nome: nome.trim(),
      renda_fixa_mensal: paraNumero(renda),
    })
    setOcupado(false)
    setEstado({ erro, salvo: !erro })
  }

  return (
    <form className="cartao" onSubmit={enviar}>
      <div className="cartao__rotulo">Você</div>
      {estado.erro && <div className="aviso aviso--erro">{estado.erro}</div>}
      {estado.salvo && <div className="aviso aviso--sucesso">Salvo.</div>}

      <label className="campo">
        <span className="campo__rotulo">Nome</span>
        <input value={nome} onChange={(e) => setNome(e.target.value)} />
      </label>

      <label className="campo">
        <span className="campo__rotulo">Renda fixa mensal</span>
        <input
          inputMode="decimal"
          value={renda}
          onChange={(e) => setRenda(e.target.value)}
          placeholder="0,00"
        />
        <span className="faixa__meta">
          É a base do 50/30/20. Hoje: {moeda(perfil?.renda_fixa_mensal ?? 0)}
        </span>
      </label>

      <div className="faixa__meta" style={{ marginBottom: 12 }}>{email}</div>

      <button className="botao" type="submit" disabled={ocupado}>
        {ocupado ? 'Salvando…' : 'Salvar'}
      </button>
    </form>
  )
}

function FormularioCategoria({ registro, aoFechar }) {
  const { criar, editar, apagar } = useDados()
  const [nome, setNome] = useState(registro?.nome ?? '')
  const [classe, setClasse] = useState(registro?.classe_padrao ?? 'variavel')
  const [cor, setCor] = useState(registro?.cor ?? '#7B1D2E')
  const [erro, setErro] = useState('')
  const [confirmando, setConfirmando] = useState(false)
  const [ocupado, setOcupado] = useState(false)

  async function salvar(evento) {
    evento.preventDefault()
    setOcupado(true)
    const campos = { nome: nome.trim(), classe_padrao: classe, cor }
    const { erro: falha } = registro
      ? await editar('categorias', registro.id, campos)
      : await criar('categorias', campos)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  async function remover() {
    setOcupado(true)
    const { erro: falha } = await apagar('categorias', registro.id)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  return (
    <Folha titulo={registro ? 'Editar categoria' : 'Nova categoria'} aoFechar={aoFechar}>
      {erro && <div className="aviso aviso--erro">{erro}</div>}
      <form onSubmit={salvar}>
        <label className="campo">
          <span className="campo__rotulo">Nome</span>
          <input value={nome} onChange={(e) => setNome(e.target.value)} required autoFocus />
        </label>

        <div className="campo">
          <span className="campo__rotulo">Classe padrão</span>
          <div className="escolha">
            {CLASSES.map((k) => (
              <button
                key={k.valor}
                type="button"
                aria-pressed={classe === k.valor}
                onClick={() => setClasse(k.valor)}
              >
                {k.rotulo}
              </button>
            ))}
          </div>
        </div>

        <label className="campo">
          <span className="campo__rotulo">Cor</span>
          <input type="color" value={cor} onChange={(e) => setCor(e.target.value)} />
        </label>

        <button className="botao" type="submit" disabled={ocupado}>
          {ocupado ? 'Salvando…' : 'Salvar'}
        </button>
      </form>

      {registro &&
        (confirmando ? (
          <div className="linha-acoes" style={{ marginTop: 10 }}>
            <button className="botao botao--secundario" onClick={() => setConfirmando(false)}>
              Cancelar
            </button>
            <button className="botao botao--perigo" onClick={remover} disabled={ocupado}>
              Apagar mesmo
            </button>
          </div>
        ) : (
          <button
            className="botao botao--perigo"
            style={{ marginTop: 10 }}
            onClick={() => setConfirmando(true)}
          >
            Apagar categoria
          </button>
        ))}
    </Folha>
  )
}
