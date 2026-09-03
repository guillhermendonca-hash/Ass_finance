import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider } from './context/AuthContext'
import { useAuth } from './context/useAuth'
import { supabaseConfigurado } from './lib/supabase'
import ConfigNecessaria from './components/ConfigNecessaria'
import Layout from './components/Layout'
import Login from './pages/Login'
import Resumo from './pages/Resumo'
import Lancar from './pages/Lancar'
import Carteira from './pages/Carteira'
import Dividas from './pages/Dividas'
import Ajustes from './pages/Ajustes'

function Rotas() {
  const { sessao, carregando } = useAuth()

  if (carregando) return <div className="carregando">Carregando…</div>
  if (!sessao) return <Login />

  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Resumo />} />
        <Route path="lancar" element={<Lancar />} />
        <Route path="carteira" element={<Carteira />} />
        <Route path="dividas" element={<Dividas />} />
        <Route path="ajustes" element={<Ajustes />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

export default function App() {
  if (!supabaseConfigurado) return <ConfigNecessaria />

  return (
    <BrowserRouter>
      <AuthProvider>
        <Rotas />
      </AuthProvider>
    </BrowserRouter>
  )
}
