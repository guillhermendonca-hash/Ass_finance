import { useAuth } from '../context/useAuth'

export default function Ajustes() {
  const { usuario, perfil, sair } = useAuth()

  return (
    <>
      <header className="cabecalho">
        <h1>Ajustes</h1>
      </header>

      <div className="cartao">
        <div className="cartao__rotulo">Conta</div>
        <div style={{ fontWeight: 600 }}>{perfil?.nome || '—'}</div>
        <div style={{ color: 'var(--texto-suave)', fontSize: 14 }}>{usuario?.email}</div>
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
        <div className="cartao__rotulo">Ainda não construída</div>
        <p style={{ color: 'var(--texto-suave)', fontSize: 14, margin: '4px 0 0' }}>
          Renda fixa mensal, categorias personalizadas, vínculo com a parceira e
          backup em JSON entram nas próximas etapas.
        </p>
      </div>

      <button
        className="botao botao--texto"
        type="button"
        onClick={sair}
        style={{ marginTop: 18 }}
      >
        Sair da conta
      </button>
    </>
  )
}
