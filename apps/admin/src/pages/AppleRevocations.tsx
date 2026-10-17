import { useState } from 'react'
import { api, type AppleRevocation } from '../api'
import { Chip, ErrorNote, ReasonDialog, Time, useLoad } from '../ui'

/**
 * Sign in with Apple records of deleted accounts. Nobody at Hiyall can revoke a member's Apple authorization (Apple's
 * revoke call needs the member's own token and the developer portal has no per-user revoke), so the member removes the
 * app's access themselves in Apple ID settings: Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID.
 *
 * - "member informed": the app told the member when it scheduled the deletion without an Apple code. A record only,
 *   removed after 90 days; nothing to do.
 * - "tell the member": support scheduled the deletion, so the app could not tell them. An operator tells them (by e-mail,
 *   with the steps above), then acknowledges the record here (audited; the record is then removed).
 *
 * The list is read-audited.
 */
export function AppleRevocations() {
  const { data, error, loading, reload } = useLoad(() => api<{ items: AppleRevocation[]; memberAction?: string }>('GET', '/apple-revocations'), 'apple')
  const [pick, setPick] = useState<AppleRevocation | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  if (loading && !data) return <p role="status">Loading…</p>
  const items = data?.items ?? []
  return (
    <section aria-labelledby="apple-title">
      <h1 id="apple-title">Apple deletions</h1>
      <p className="hint">Hiyall cannot revoke a member’s Sign in with Apple authorization for them. The member removes it in Apple ID settings (Settings &gt; Apple ID &gt; Sign in with Apple &gt; Hiyall &gt; Stop using Apple ID). The app tells them so when they delete their account. For a deletion that support scheduled, tell the member and then acknowledge the record. These rows hold no token.</p>
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />
      {items.length === 0 && !error && <p>Nothing to do.</p>}
      {items.length > 0 && (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Apple records of deleted accounts, those needing an operator first</caption>
            <thead><tr><th scope="col">Account</th><th scope="col">State</th><th scope="col">Why</th><th scope="col">Recorded</th><th scope="col"><span className="sr-only">Action</span></th></tr></thead>
            <tbody>
              {items.map((r) => (
                <tr key={r.revocationId}>
                  <td><code>{r.userId || 'unknown'}</code></td>
                  <td>{r.status === 'manual' ? <Chip kind="warn">tell the member</Chip> : <Chip kind="neutral">member informed</Chip>}</td>
                  <td>{r.reason}</td>
                  <td><Time value={r.createdAt} /></td>
                  <td><button type="button" className="secondary" onClick={() => setPick(r)}>Acknowledge…</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {pick && (
        <ReasonDialog
          title="Acknowledge the Apple record"
          confirmLabel="Acknowledge"
          intro={<p>{pick.status === 'manual' ? 'Confirm that you told the member to remove Hiyall in Apple ID settings. Say how (an e-mail, a ticket, the date).' : 'The app already told the member. Acknowledging removes this record early; say why.'}</p>}
          onSubmit={async (reason) => {
            await api('POST', `/apple-revocations/${pick.revocationId}/acknowledge`, { reason })
            setPick(null)
            setNotice('Acknowledged and recorded in the audit log.')
            await reload()
          }}
          onClose={() => setPick(null)}
        />
      )}
    </section>
  )
}
