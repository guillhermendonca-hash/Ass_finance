import { useEffect } from 'react'

/** Folha que sobe de baixo — o formulário no celular, sem sair da tela. */
export default function Folha({ titulo, aoFechar, children }) {
  useEffect(() => {
    const naTecla = (e) => e.key === 'Escape' && aoFechar()
    document.addEventListener('keydown', naTecla)
    return () => document.removeEventListener('keydown', naTecla)
  }, [aoFechar])

  return (
    <div
      className="folha__fundo"
      onClick={(e) => e.target === e.currentTarget && aoFechar()}
      role="presentation"
    >
      <div className="folha" role="dialog" aria-modal="true" aria-label={titulo}>
        <div className="folha__topo">
          <h2>{titulo}</h2>
          <button type="button" className="folha__fechar" onClick={aoFechar} aria-label="Fechar">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}
