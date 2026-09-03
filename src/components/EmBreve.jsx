/** Marcador das telas que chegam nas próximas etapas da Fase 1 e na Fase 2. */
export default function EmBreve({ titulo, subtitulo, descricao }) {
  return (
    <>
      <header className="cabecalho">
        <h1>{titulo}</h1>
        {subtitulo && <span className="subtitulo">{subtitulo}</span>}
      </header>
      <div className="cartao">
        <div className="vazio">
          <div className="vazio__titulo">Ainda não construída</div>
          <p>{descricao}</p>
        </div>
      </div>
    </>
  )
}
