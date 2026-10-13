import type { ReactNode } from 'react'
import { Link, NavLink, Route, Routes } from 'react-router'
import { AuthProvider, useAuth } from './auth'
import type { Role } from './api'
import { Account } from './pages/Account'
import { Audit } from './pages/Audit'
import { Case } from './pages/Case'
import { Login } from './pages/Login'
import { Operators } from './pages/Operators'
import { Queue } from './pages/Queue'
import { User } from './pages/User'

export function App() {
  return (
    <AuthProvider>
      <Shell />
    </AuthProvider>
  )
}

function Guard({ role, children }: { role: Role; children: ReactNode }) {
  const { state } = useAuth()
  if (state.status !== 'in') return null
  if (state.operator.role !== role) return <p role="alert" className="error">Your role does not allow this page.</p>
  return <>{children}</>
}

function Shell() {
  const { state, signOut } = useAuth()
  if (state.status === 'loading') return <p role="status" className="center">Loading…</p>
  if (state.status === 'anon') return <Login />
  const op = state.operator
  return (
    <>
      <a href="#main" className="skip">Skip to content</a>
      <header className="bar">
        <Link to="/" className="brand">Hiyall Admin</Link>
        <nav aria-label="Main">
          <NavLink to="/" end>Reports</NavLink>
          {op.role === 'admin' && <NavLink to="/audit">Audit log</NavLink>}
          {op.role === 'admin' && <NavLink to="/operators">Operators</NavLink>}
          <NavLink to="/account">Account</NavLink>
        </nav>
        <span className="who">{op.displayName} · {op.role}</span>
        <button type="button" className="secondary" onClick={() => void signOut()}>Sign out</button>
      </header>
      <main id="main" tabIndex={-1}>
        <Routes>
          <Route path="/" element={<Queue />} />
          <Route path="/reports/:id" element={<Case />} />
          <Route path="/users/:id" element={<User />} />
          <Route path="/audit" element={<Guard role="admin"><Audit /></Guard>} />
          <Route path="/operators" element={<Guard role="admin"><Operators /></Guard>} />
          <Route path="/account" element={<Account />} />
          <Route path="*" element={<p>Page not found.</p>} />
        </Routes>
      </main>
    </>
  )
}
