import { useMemo } from 'react'
import { useDados } from '../context/useDados'
import { useAuth } from '../context/useAuth'
import { moeda, dataCurta } from '../lib/formato'
import { intervaloDoMes, nomeDoMes } from '../lib/periodo'
import { diagnostico, faturaAberta } from '../lib/diagnostico'
import Barra from '../components/Barra'

const CORES = {
  essencial: 'var(--bordeaux)',
  variavel: 'var(--ambar)',
  sobra: 'var(--verde)',
}

export default function Resumo() {
  const { perfil } = useAuth()
  const { contas, cartoes, lancamentos, carregando } = useDados()

  const { inicio, fim } = intervaloDoMes()
  const doMes = useMemo(
    () => lancamentos.filter((l) => l.data >= inicio && l.data <= fim),
    [lancamentos, inicio, fim],
  )

  const d = useMemo(
    () => diagnostico(doMes, perfil?.renda_fixa_mensal),
    [doMes, perfil],
  )

  if (carregando) return <div className="carregando">Carregando…</div>

  const saldoEmContas = contas.reduce((t, c) => t + Number(c.saldo_atual), 0)
  const noVermelho = d.sobra < 0

  return (
    <>
      <header className="cabecalho">
        <h1>Resumo</h1>
        <span className="subtitulo">{nomeDoMes()}</span>
      </header>

      <div className="cartao">
        <div className="cartao__rotulo">Saldo em contas</div>
        <div className="cartao__valor">{moeda(saldoEmContas)}</div>
        <div className="faixa__meta" style={{ marginTop: 4 }}>
          {contas.length
            ? `${contas.length} ${contas.length === 1 ? 'conta' : 'contas'}`
            : 'Nenhuma conta cadastrada ainda'}
        </div>
      </div>

      <div className="cartao">
        <div className="cartao__rotulo">Sobra do mês</div>
        <div className={`cartao__valor ${noVermelho ? 'valor--negativo' : 'valor--positivo'}`}>
          {moeda(d.sobra)}
        </div>
        <div className="faixa__meta" style={{ marginTop: 4 }}>
          {moeda(d.base)} de renda − {moeda(d.gastos)} de gastos
          {d.baseVemDosLancamentos && d.base > 0 && ' · base vinda das receitas lançadas'}
        </div>
      </div>

      {d.base === 0 && (
        <div className="aviso aviso--info" style={{ marginTop: 14 }}>
          Informe a sua renda fixa mensal em Ajustes — sem ela o 50/30/20 não tem
          contra o que medir.
        </div>
      )}

      <div className="cartao">
        <div className="cartao__rotulo">Diagnóstico 50/30/20</div>
        {d.faixas.map((faixa) => {
          const negativa = faixa.valor < 0
          return (
            <div className="faixa" key={faixa.chave}>
              <div className="faixa__topo">
                <span>{faixa.rotulo}</span>
                <span className={`faixa__valor ${negativa ? 'valor--negativo' : ''}`}>
                  {moeda(faixa.valor)}
                </span>
              </div>
              <Barra
                fatia={faixa.fatia}
                cor={negativa ? 'var(--vermelho)' : CORES[faixa.chave]}
                alvo={faixa.alvo}
              />
              <div className="faixa__meta">
                {Math.round(faixa.fatia * 100)}% · meta {Math.round(faixa.alvo * 100)}%
              </div>
            </div>
          )
        })}
        <p className="faixa__meta" style={{ marginTop: 14 }}>
          O traço em cada barra é a meta. Na recuperação os 20% vão primeiro para
          a reserva mínima e depois inteiros para a dívida.
        </p>
      </div>

      {cartoes.length > 0 && (
        <div className="cartao">
          <div className="cartao__rotulo">Faturas em aberto</div>
          {cartoes.map((cartao) => {
            const fatura = faturaAberta(cartao, lancamentos)
            const apertado = fatura.uso >= 0.8
            return (
              <div className="faixa" key={cartao.id}>
                <div className="faixa__topo">
                  <span>{cartao.nome}</span>
                  <span className={`faixa__valor ${apertado ? 'valor--negativo' : ''}`}>
                    {moeda(fatura.total)}
                  </span>
                </div>
                <Barra
                  fatia={fatura.uso}
                  cor={apertado ? 'var(--vermelho)' : 'var(--bordeaux)'}
                  alvo={0.8}
                />
                <div className="faixa__meta">
                  {Math.round(fatura.uso * 100)}% do limite · fecha {dataCurta(fatura.fim)} ·
                  vence dia {cartao.dia_vencimento}
                </div>
              </div>
            )
          })}
        </div>
      )}

      <div className="cartao">
        <div className="cartao__rotulo">Ainda não construído</div>
        <p style={{ color: 'var(--texto-suave)', fontSize: 14, margin: '4px 0 0' }}>
          Total em dívidas, próximo alvo de ataque e a frase de recomendação ativa
          chegam na Fase 2. Até lá a sobra do mês não desconta parcelas mínimas,
          porque ainda não há dívidas cadastradas.
        </p>
      </div>
    </>
  )
}
