import { useMemo, useState } from 'react'
import { useDados } from '../context/useDados'
import { moeda, dataCurta, paraNumero } from '../lib/formato'
import { iso } from '../lib/periodo'
import SeletorVisibilidade, { Selo } from '../components/SeletorVisibilidade'

const hojeISO = () => iso(new Date())

export default function Lancar() {
  const { contas, cartoes, categorias, lancamentos, criar, apagar, carregando } = useDados()

  const [tipo, setTipo] = useState('gasto')
  const [valor, setValor] = useState('')
  const [classe, setClasse] = useState('variavel')
  const [categoriaId, setCategoriaId] = useState('')
  const [origem, setOrigem] = useState('') // '' | 'conta:<id>' | 'cartao:<id>'
  const [data, setData] = useState(hojeISO)
  const [visibilidade, setVisibilidade] = useState('privado')
  const [descricao, setDescricao] = useState('')
  const [erro, setErro] = useState('')
  const [ocupado, setOcupado] = useState(false)

  const ehReceita = tipo === 'receita'

  const categoriasVisiveis = useMemo(
    () =>
      categorias.filter((c) =>
        ehReceita ? c.classe_padrao === 'receita' : c.classe_padrao !== 'receita',
      ),
    [categorias, ehReceita],
  )

  function trocarTipo(novo) {
    setTipo(novo)
    setClasse(novo === 'receita' ? 'receita' : 'variavel')
    setCategoriaId('')
  }

  // Escolher a categoria já ajusta a classe: menos um toque no caminho.
  function escolherCategoria(id) {
    setCategoriaId(id)
    const cat = categorias.find((c) => c.id === id)
    if (cat && !ehReceita && cat.classe_padrao !== 'receita') setClasse(cat.classe_padrao)
  }

  async function enviar(evento) {
    evento.preventDefault()
    setErro('')

    const numero = paraNumero(valor)
    if (numero <= 0) return setErro('Informe um valor maior que zero.')

    const [tipoOrigem, idOrigem] = origem ? origem.split(':') : []
    setOcupado(true)
    const { erro: falha } = await criar('lancamentos', {
      tipo,
      valor: numero,
      classe: ehReceita ? 'receita' : classe,
      categoria_id: categoriaId || null,
      conta_id: tipoOrigem === 'conta' ? idOrigem : null,
      cartao_id: tipoOrigem === 'cartao' ? idOrigem : null,
      data,
      visibilidade,
      descricao: descricao.trim() || null,
    })
    setOcupado(false)

    if (falha) return setErro(falha)

    // Limpa o que muda a cada lançamento e devolve a visibilidade ao
    // padrão: todo lançamento nasce privado.
    setValor('')
    setDescricao('')
    setCategoriaId('')
    setVisibilidade('privado')
  }

  if (carregando) return <div className="carregando">Carregando…</div>

  return (
    <>
      <header className="cabecalho">
        <h1>Lançar</h1>
      </header>

      {erro && <div className="aviso aviso--erro">{erro}</div>}

      <form onSubmit={enviar} className="cartao">
        <div className={`escolha ${ehReceita ? 'escolha--verde' : ''}`}>
          <button type="button" aria-pressed={!ehReceita} onClick={() => trocarTipo('gasto')}>
            Gasto
          </button>
          <button type="button" aria-pressed={ehReceita} onClick={() => trocarTipo('receita')}>
            Recebi
          </button>
        </div>

        <input
          className={`valor-grande ${ehReceita ? 'valor-grande--receita' : ''}`}
          inputMode="decimal"
          value={valor}
          onChange={(e) => setValor(e.target.value)}
          placeholder="0,00"
          aria-label="Valor"
          required
        />

        {!ehReceita && (
          <div className="escolha" style={{ marginBottom: 14 }}>
            <button
              type="button"
              aria-pressed={classe === 'essencial'}
              onClick={() => setClasse('essencial')}
            >
              Essencial
            </button>
            <button
              type="button"
              aria-pressed={classe === 'variavel'}
              onClick={() => setClasse('variavel')}
            >
              Variável
            </button>
          </div>
        )}

        <label className="campo">
          <span className="campo__rotulo">Categoria</span>
          <select value={categoriaId} onChange={(e) => escolherCategoria(e.target.value)}>
            <option value="">Sem categoria</option>
            {categoriasVisiveis.map((c) => (
              <option key={c.id} value={c.id}>
                {c.nome}
              </option>
            ))}
          </select>
        </label>

        <label className="campo">
          <span className="campo__rotulo">Conta ou cartão</span>
          <select value={origem} onChange={(e) => setOrigem(e.target.value)}>
            <option value="">Não vincular</option>
            {contas.length > 0 && (
              <optgroup label="Contas">
                {contas.map((c) => (
                  <option key={c.id} value={`conta:${c.id}`}>
                    {c.nome}
                  </option>
                ))}
              </optgroup>
            )}
            {cartoes.length > 0 && (
              <optgroup label="Cartões">
                {cartoes.map((c) => (
                  <option key={c.id} value={`cartao:${c.id}`}>
                    {c.nome}
                  </option>
                ))}
              </optgroup>
            )}
          </select>
        </label>

        <label className="campo">
          <span className="campo__rotulo">Data</span>
          <input type="date" value={data} onChange={(e) => setData(e.target.value)} required />
        </label>

        <SeletorVisibilidade valor={visibilidade} aoMudar={setVisibilidade} />

        <label className="campo">
          <span className="campo__rotulo">Descrição (opcional)</span>
          <input
            value={descricao}
            onChange={(e) => setDescricao(e.target.value)}
            placeholder="mercado, uber, consulta…"
          />
        </label>

        <button className="botao" type="submit" disabled={ocupado}>
          {ocupado ? 'Lançando…' : ehReceita ? 'Registrar entrada' : 'Registrar gasto'}
        </button>
      </form>

      <Recentes
        lancamentos={lancamentos}
        contas={contas}
        cartoes={cartoes}
        categorias={categorias}
        aoApagar={(id) => apagar('lancamentos', id)}
      />
    </>
  )
}

function Recentes({ lancamentos, contas, cartoes, categorias, aoApagar }) {
  const nomes = useMemo(() => {
    const mapa = new Map()
    for (const lista of [contas, cartoes, categorias]) {
      for (const item of lista) mapa.set(item.id, item)
    }
    return mapa
  }, [contas, cartoes, categorias])

  if (!lancamentos.length)
    return (
      <div className="cartao">
        <div className="vazio">
          <div className="vazio__titulo">Nada lançado ainda</div>
          <p>O primeiro gasto registrado é o que faz o resto do app funcionar.</p>
        </div>
      </div>
    )

  return (
    <div className="cartao">
      <div className="cartao__rotulo">Últimos lançamentos</div>
      {lancamentos.slice(0, 12).map((l) => {
        const categoria = nomes.get(l.categoria_id)
        const origem = nomes.get(l.conta_id ?? l.cartao_id)
        const ehReceita = l.tipo === 'receita'
        return (
          <div key={l.id} className="item">
            <span className="item__nome">
              {categoria && (
                <span className="ponto-cor" style={{ background: categoria.cor }} />
              )}
              {l.descricao || categoria?.nome || 'Sem categoria'}{' '}
              <Selo visibilidade={l.visibilidade} />
            </span>
            <span className={`item__valor ${ehReceita ? 'valor--positivo' : ''}`}>
              {ehReceita ? '+' : '−'}
              {moeda(l.valor).replace('R$', '').trim()}
            </span>
            <button
              className="item__acao"
              onClick={() => aoApagar(l.id)}
              aria-label={`Apagar lançamento de ${moeda(l.valor)}`}
              title="Apagar"
            >
              ×
            </button>
            <span className="item__nota">
              {dataCurta(l.data)}
              {origem ? ` · ${origem.nome}` : ''}
              {!ehReceita ? ` · ${l.classe === 'essencial' ? 'essencial' : 'variável'}` : ''}
            </span>
          </div>
        )
      })}
    </div>
  )
}
