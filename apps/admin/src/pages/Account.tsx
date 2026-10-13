import { useState, type FormEvent } from 'react'
import { api } from '../api'
import { useOperator } from '../auth'
import { ErrorNote, messageOf } from '../ui'

export function Account() {
  const me = useOperator()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setDone(false)
    try {
      await api('POST', '/me/password', { current, new: next })
      setCurrent('')
      setNext('')
      setDone(true)
    } catch (err) {
      setError(messageOf(err))
    }
  }

  return (
    <section aria-labelledby="account-title">
      <h1 id="account-title">Account</h1>
      <p>{me.displayName} · {me.email} · role <strong>{me.role}</strong></p>
      <form onSubmit={submit} aria-label="Change password">
        <h2>Change password</h2>
        <label htmlFor="current">Current password</label>
        <input id="current" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} required />
        <label htmlFor="new">New password (at least 12 characters)</label>
        <input id="new" type="password" autoComplete="new-password" minLength={12} value={next} onChange={(e) => setNext(e.target.value)} required />
        <ErrorNote error={error} />
        {done && <p role="status" className="notice">Password changed. Your other sessions were signed out.</p>}
        <button type="submit" className="primary">Change password</button>
      </form>
    </section>
  )
}
