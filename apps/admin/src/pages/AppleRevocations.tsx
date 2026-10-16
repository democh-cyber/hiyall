import { useState } from 'react'
import { api, type AppleRevocation } from '../api'
import { ErrorNote, ReasonDialog, Time, useLoad } from '../ui'

/**
 * Sign in with Apple authorizations that the server could not revoke when an account was deleted: the app could not
 * get an authorization code, or support scheduled the deletion. An operator revokes each one by hand in Apple's
 * developer console and then marks it done here (audited; the entry is then removed). The list is read-audited.
 */
export function AppleRevocations() {
  const { data, error, loading, reload } = useLoad(() => api<{ items: AppleRevocation[] }>('GET', '/apple-revocations'), 'apple')
  const [pick, setPick] = useState<AppleRevocation | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  if (loading && !data) return <p role="status">Loading…</p>
  const items = data?.items ?? []
  return (
    <section aria-labelledby="apple-title">
      <h1 id="apple-title">Apple revocations to do by hand</h1>
      <p className="hint">The member asked to delete the account but the server could not revoke their Sign in with Apple authorization. Revoke it in Apple’s developer console, then mark it done. These rows hold no token.</p>
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />
      {items.length === 0 && !error && <p>Nothing to revoke.</p>}
      {items.length > 0 && (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Manual Apple revocations, oldest first</caption>
            <thead><tr><th scope="col">Account</th><th scope="col">Identity</th><th scope="col">Why</th><th scope="col">Queued</th><th scope="col"><span className="sr-only">Action</span></th></tr></thead>
            <tbody>
              {items.map((r) => (
                <tr key={r.revocationId}>
                  <td><code>{r.userId || 'unknown'}</code></td>
                  <td><code>{r.subject}</code></td>
                  <td>{r.reason}</td>
                  <td><Time value={r.createdAt} /></td>
                  <td><button type="button" className="secondary" onClick={() => setPick(r)}>Mark revoked…</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {pick && (
        <ReasonDialog
          title="Mark the Apple authorization revoked"
          confirmLabel="Mark revoked"
          intro={<p>Confirm that you revoked the Sign in with Apple authorization for this account in Apple’s console. Say how you checked (a ticket or the date).</p>}
          onSubmit={async (reason) => {
            await api('POST', `/apple-revocations/${pick.revocationId}/revoked`, { reason })
            setPick(null)
            setNotice('Marked revoked and recorded in the audit log.')
            await reload()
          }}
          onClose={() => setPick(null)}
        />
      )}
    </section>
  )
}
