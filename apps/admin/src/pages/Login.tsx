import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useAuth } from '../auth'
import { ApiError } from '../api'
import { ErrorNote } from '../ui'

/** Two screens, one request: the password and the code are sent together, so the server never reveals which was wrong. */
export function Login() {
  const { signIn } = useAuth()
  const [step, setStep] = useState<'password' | 'code'>('password')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [code, setCode] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const codeRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (step === 'code') codeRef.current?.focus()
  }, [step])

  function next(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setStep('code')
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await signIn(email, password, code)
    } catch (err) {
      setPassword('')
      setCode('')
      setStep('password')
      setError(err instanceof ApiError && err.status === 429 ? err.message : 'Sign-in failed. Check your details and try again.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="login">
      <h1>Hiyall Admin</h1>
      <p className="muted">Staff only. Every action here is recorded.</p>
      {step === 'password' ? (
        <form onSubmit={next} aria-label="Sign in">
          <label htmlFor="email">Email</label>
          <input id="email" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus />
          <label htmlFor="password">Password</label>
          <input id="password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          <ErrorNote error={error} />
          <button type="submit" className="primary">Continue</button>
        </form>
      ) : (
        <form onSubmit={submit} aria-label="Second step">
          <label htmlFor="code">Authenticator code</label>
          <input id="code" ref={codeRef} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9 ]{6,7}" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} required />
          <p className="hint">The 6 digit code from your authenticator app. A code works once.</p>
          <ErrorNote error={error} />
          <div className="actions">
            <button type="button" className="secondary" onClick={() => setStep('password')}>Back</button>
            <button type="submit" className="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
          </div>
        </form>
      )}
    </main>
  )
}
