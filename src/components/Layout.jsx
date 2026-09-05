import { NavLink, Outlet } from 'react-router-dom'

const abas = [
  { para: '/', icone: '◆', texto: 'Resumo', fim: true },
  { para: '/lancar', icone: '+', texto: 'Lançar' },
  { para: '/carteira', icone: '▤', texto: 'Carteira' },
  { para: '/dividas', icone: '↓', texto: 'Dívidas' },
  { para: '/ajustes', icone: '⚙', texto: 'Ajustes' },
]

export default function Layout() {
  return (
    <div className="app">
      <main className="conteudo">
        <Outlet />
      </main>
      <nav className="nav">
        {abas.map(({ para, icone, texto, fim }) => (
          <NavLink
            key={para}
            to={para}
            end={fim}
            className={({ isActive }) => (isActive ? 'ativo' : undefined)}
          >
            <span className="nav__icone" aria-hidden="true">
              {icone}
            </span>
            {texto}
          </NavLink>
        ))}
      </nav>
    </div>
  )
}
