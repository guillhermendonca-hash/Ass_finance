import { useState } from 'react'
import { useDados } from '../context/useDados'
import { moeda, paraNumero, dataCurta } from '../lib/formato'
import { faturaAberta } from '../lib/diagnostico'
import Folha from '../components/Folha'
import Barra from '../components/Barra'
import SeletorVisibilidade, { Selo } from '../components/SeletorVisibilidade'

export default function Carteira() {
  const { contas, cartoes, lancamentos, carregando } = useDados()
  const [aba, setAba] = useState('contas')
  const [editando, setEditando] = useState(null)

  if (carregando) return <div className="carregando">Carregando…</div>

  const emContas = aba === 'contas'

  return (
    <>
      <header className="cabecalho">
        <h1>Carteira</h1>
      </header>

      <div className="abas" role="tablist">
        <button role="tab" aria-selected={emContas} onClick={() => setAba('contas')}>
          Contas
        </button>
        <button role="tab" aria-selected={!emContas} onClick={() => setAba('cartoes')}>
          Cartões
        </button>
      </div>

      {emContas ? (
        <ListaContas contas={contas} aoAbrir={(c) => setEditando({ tipo: 'conta', registro: c })} />
      ) : (
        <ListaCartoes
          cartoes={cartoes}
          lancamentos={lancamentos}
          aoAbrir={(c) => setEditando({ tipo: 'cartao', registro: c })}
        />
      )}

      <button
        className="botao"
        style={{ marginTop: 16 }}
        onClick={() => setEditando({ tipo: emContas ? 'conta' : 'cartao', registro: null })}
      >
        {emContas ? 'Nova conta' : 'Novo cartão'}
      </button>

      {editando?.tipo === 'conta' && (
        <FormularioConta registro={editando.registro} aoFechar={() => setEditando(null)} />
      )}
      {editando?.tipo === 'cartao' && (
        <FormularioCartao registro={editando.registro} aoFechar={() => setEditando(null)} />
      )}
    </>
  )
}

/* ------------------------------------------------------------ contas */

function ListaContas({ contas, aoAbrir }) {
  const total = contas.reduce((t, c) => t + Number(c.saldo_atual), 0)

  if (!contas.length)
    return (
      <div className="cartao">
        <div className="vazio">
          <div className="vazio__titulo">Nenhuma conta ainda</div>
          <p>Cadastre onde o seu dinheiro fica: conta corrente, poupança, carteira.</p>
        </div>
      </div>
    )

  return (
    <div className="cartao">
      <div className="cartao__rotulo">Saldo somado</div>
      <div className="cartao__valor" style={{ marginBottom: 10 }}>
        {moeda(total)}
      </div>
      {contas.map((conta) => (
        <div
          key={conta.id}
          className="item item--clicavel"
          onClick={() => aoAbrir(conta)}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && aoAbrir(conta)}
        >
          <span className="item__nome">
            {conta.nome} <Selo visibilidade={conta.visibilidade} />
          </span>
          <span className="item__valor">{moeda(conta.saldo_atual)}</span>
        </div>
      ))}
    </div>
  )
}

function FormularioConta({ registro, aoFechar }) {
  const { criar, editar, apagar } = useDados()
  const [nome, setNome] = useState(registro?.nome ?? '')
  const [saldo, setSaldo] = useState(registro ? String(registro.saldo_atual) : '')
  const [visibilidade, setVisibilidade] = useState(registro?.visibilidade ?? 'privado')
  const [erro, setErro] = useState('')
  const [confirmando, setConfirmando] = useState(false)
  const [ocupado, setOcupado] = useState(false)

  async function salvar(evento) {
    evento.preventDefault()
    setOcupado(true)
    const campos = { nome: nome.trim(), saldo_atual: paraNumero(saldo), visibilidade }
    const { erro: falha } = registro
      ? await editar('contas', registro.id, campos)
      : await criar('contas', campos)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  async function remover() {
    setOcupado(true)
    const { erro: falha } = await apagar('contas', registro.id)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  return (
    <Folha titulo={registro ? 'Editar conta' : 'Nova conta'} aoFechar={aoFechar}>
      {erro && <div className="aviso aviso--erro">{erro}</div>}
      <form onSubmit={salvar}>
        <label className="campo">
          <span className="campo__rotulo">Nome</span>
          <input value={nome} onChange={(e) => setNome(e.target.value)} required autoFocus />
        </label>

        <label className="campo">
          <span className="campo__rotulo">Saldo atual</span>
          <input
            inputMode="decimal"
            value={saldo}
            onChange={(e) => setSaldo(e.target.value)}
            placeholder="0,00"
          />
        </label>

        <SeletorVisibilidade valor={visibilidade} aoMudar={setVisibilidade} />

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
            Apagar conta
          </button>
        ))}
    </Folha>
  )
}

/* ----------------------------------------------------------- cartões */

function ListaCartoes({ cartoes, lancamentos, aoAbrir }) {
  if (!cartoes.length)
    return (
      <div className="cartao">
        <div className="vazio">
          <div className="vazio__titulo">Nenhum cartão ainda</div>
          <p>Cadastre limite, dia de fechamento e de vencimento para a fatura aparecer sozinha.</p>
        </div>
      </div>
    )

  return (
    <div className="pilha">
      {cartoes.map((cartao) => {
        const fatura = faturaAberta(cartao, lancamentos)
        const apertado = fatura.uso >= 0.8
        return (
          <div
            key={cartao.id}
            className="cartao item--clicavel"
            onClick={() => aoAbrir(cartao)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => e.key === 'Enter' && aoAbrir(cartao)}
          >
            <div className="faixa__topo" style={{ marginBottom: 8 }}>
              <span className="item__nome">
                {cartao.nome} <Selo visibilidade={cartao.visibilidade} />
              </span>
              <span className={`faixa__valor ${apertado ? 'valor--negativo' : ''}`}>
                {moeda(fatura.total)}
              </span>
            </div>

            <Barra
              fatia={fatura.uso}
              cor={apertado ? 'var(--vermelho)' : 'var(--bordeaux)'}
              alvo={0.8}
            />

            <div className="faixa__meta" style={{ marginTop: 7 }}>
              {Math.round(fatura.uso * 100)}% de {moeda(cartao.limite)} · fatura aberta até{' '}
              {dataCurta(fatura.fim)} · vence dia {cartao.dia_vencimento}
            </div>
          </div>
        )
      })}
    </div>
  )
}

function FormularioCartao({ registro, aoFechar }) {
  const { criar, editar, apagar } = useDados()
  const [nome, setNome] = useState(registro?.nome ?? '')
  const [limite, setLimite] = useState(registro ? String(registro.limite) : '')
  const [fechamento, setFechamento] = useState(String(registro?.dia_fechamento ?? 10))
  const [vencimento, setVencimento] = useState(String(registro?.dia_vencimento ?? 17))
  const [visibilidade, setVisibilidade] = useState(registro?.visibilidade ?? 'privado')
  const [erro, setErro] = useState('')
  const [confirmando, setConfirmando] = useState(false)
  const [ocupado, setOcupado] = useState(false)

  async function salvar(evento) {
    evento.preventDefault()
    setOcupado(true)
    const campos = {
      nome: nome.trim(),
      limite: paraNumero(limite),
      dia_fechamento: Number(fechamento),
      dia_vencimento: Number(vencimento),
      visibilidade,
    }
    const { erro: falha } = registro
      ? await editar('cartoes', registro.id, campos)
      : await criar('cartoes', campos)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  async function remover() {
    setOcupado(true)
    const { erro: falha } = await apagar('cartoes', registro.id)
    setOcupado(false)
    falha ? setErro(falha) : aoFechar()
  }

  return (
    <Folha titulo={registro ? 'Editar cartão' : 'Novo cartão'} aoFechar={aoFechar}>
      {erro && <div className="aviso aviso--erro">{erro}</div>}
      <form onSubmit={salvar}>
        <label className="campo">
          <span className="campo__rotulo">Nome</span>
          <input value={nome} onChange={(e) => setNome(e.target.value)} required autoFocus />
        </label>

        <label className="campo">
          <span className="campo__rotulo">Limite</span>
          <input
            inputMode="decimal"
            value={limite}
            onChange={(e) => setLimite(e.target.value)}
            placeholder="0,00"
          />
        </label>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <label className="campo">
            <span className="campo__rotulo">Dia do fechamento</span>
            <input
              type="number"
              min="1"
              max="31"
              value={fechamento}
              onChange={(e) => setFechamento(e.target.value)}
              required
            />
          </label>
          <label className="campo">
            <span className="campo__rotulo">Dia do vencimento</span>
            <input
              type="number"
              min="1"
              max="31"
              value={vencimento}
              onChange={(e) => setVencimento(e.target.value)}
              required
            />
          </label>
        </div>

        <SeletorVisibilidade valor={visibilidade} aoMudar={setVisibilidade} />

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
            Apagar cartão
          </button>
        ))}
    </Folha>
  )
}
