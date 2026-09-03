/**
 * Barra de proporção. `alvo` marca onde a meta cai (o 50, o 30, o 20 —
 * ou os 80% de uso do limite do cartão).
 */
export default function Barra({ fatia, cor, alvo }) {
  const largura = Math.max(0, Math.min(1, fatia)) * 100
  return (
    <div className="barra">
      <div
        className="barra__preenchimento"
        style={{ width: `${largura}%`, background: cor }}
      />
      {alvo != null && <div className="barra__alvo" style={{ left: `${alvo * 100}%` }} />}
    </div>
  )
}
