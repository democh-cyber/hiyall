import { Link } from 'react-router'
import { api, approvalKindText, type ApprovalList } from '../api'
import { Chip, ErrorNote, Time, useLoad } from '../ui'

/**
 * Everything waiting for a second administrator: clearing a quarantine case, releasing an evidence hold,
 * lifting a legal hold. The proposer cannot approve their own; the decision is made on the case page, with a reason.
 */
export function Approvals() {
  const { data, error, loading } = useLoad(() => api<ApprovalList>('GET', '/approvals?status=pending'), 'pending')
  if (loading && !data) return <p role="status">Loading…</p>
  const items = data?.items ?? []
  return (
    <section aria-labelledby="approvals-title">
      <h1 id="approvals-title">Waiting for a second administrator</h1>
      <ErrorNote error={error} />
      {items.length === 0 && !error && <p>Nothing is waiting.</p>}
      {items.length > 0 && (
        <table>
          <thead><tr><th>Step</th><th>Proposed by</th><th>Reason</th><th>Expires</th><th><span className="sr-only">Open</span></th></tr></thead>
          <tbody>
            {items.map((a) => {
              const mine = a.proposedBy === data?.operatorId
              return (
                <tr key={a.approvalId}>
                  <td>{approvalKindText[a.kind]}{a.counselReference && <> <Chip kind="neutral">counsel: {a.counselReference}</Chip></>}</td>
                  <td>{mine ? 'you' : a.proposedByEmail}</td>
                  <td>{a.reason}</td>
                  <td><Time value={a.expiresAt} /></td>
                  <td><Link to={`/content/${a.caseId}`}>{mine ? 'Open case (waiting for someone else)' : 'Open case to decide'}</Link></td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}
    </section>
  )
}
