import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api, ApiError, setCsrf, setSignedOutHandler, type Operator, type SessionInfo } from './api'

type State = { status: 'loading' } | { status: 'anon' } | { status: 'in'; operator: Operator }

interface Auth {
  state: State
  signIn: (email: string, password: string, code: string) => Promise<void>
  signOut: () => Promise<void>
}

const Ctx = createContext<Auth | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<State>({ status: 'loading' })

  useEffect(() => {
    setSignedOutHandler(() => {
      setCsrf('')
      setState({ status: 'anon' })
    })
    api<SessionInfo>('GET', '/me')
      .then((s) => {
        setCsrf(s.csrfToken)
        setState({ status: 'in', operator: s.operator })
      })
      .catch(() => setState({ status: 'anon' }))
  }, [])

  const signIn = useCallback(async (email: string, password: string, code: string) => {
    const s = await api<SessionInfo>('POST', '/login', { email, password, code })
    setCsrf(s.csrfToken)
    setState({ status: 'in', operator: s.operator })
  }, [])

  const signOut = useCallback(async () => {
    try {
      await api('POST', '/logout', {})
    } catch (e) {
      if (!(e instanceof ApiError)) throw e
    }
    setCsrf('')
    setState({ status: 'anon' })
  }, [])

  const value = useMemo(() => ({ state, signIn, signOut }), [state, signIn, signOut])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useAuth(): Auth {
  const v = useContext(Ctx)
  if (!v) throw new Error('AuthProvider missing')
  return v
}

export function useOperator(): Operator {
  const { state } = useAuth()
  if (state.status !== 'in') throw new Error('not signed in')
  return state.operator
}
