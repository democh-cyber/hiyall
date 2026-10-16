import { useState } from 'react'
import { Link } from 'react-router'
import { api, approvalKindText, type ApprovalList, type EvidenceApproval } from '../api'
import { Chip, ErrorNote, ReasonDialog, Time, useLoad } from '../ui'

type Decision = { decide: 'approve' | 'reject' | 'withdraw'; approval: EvidenceApproval } | null

/**
 * Everything waiting for a second administrator: clearing a quarantine case, releasing an evidence hold, lifting a
 * legal hold, and making an operator an administrator. The proposer cannot approve their own. A case step is decided on
 * the case page, with a reason; an administrator promotion has no case, so it is decided here. With fewer than two active
 * administrators none of it can ever be completed, and the page says so.
 */
export function Approvals() {
  const { data, error, loading, reload } = useLoad(() => api<ApprovalList>('GET', '/approvals?status=pending'), 'pending')
  const [decision, setDecision] = useState<Decision>(null)
  const [notice, setNotice] = useState<string | null>(null)
  if (loading && !data) return <p role="status">Loading…</p>
  const items = data?.items ?? []
  const admins = data?.activeAdmins
  return (
    <section aria-labelledby="approvals-title">
      <h1 id="approvals-title">Waiting for a second administrator</h1>
      {admins !== undefined && admins < 2 && (
        <p role="alert" className="error">
          Only {admins} active administrator{admins === 1 ? '' : 's'}: nothing here can be approved until there are two. Create another on the server with <code>admin operator-add -role admin</code>.
        </p>
      )}
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />
      {items.length === 0 && !error && <p>Nothing is waiting.</p>}
      {items.length > 0 && (
        <table>
          <thead><tr><th>Step</th><th>Proposed by</th><th>Reason</th><th>Expires</th><th><span className="sr-only">Open</span></th></tr></thead>
          <tbody>
            {items.map((a) => {
              const mine = a.proposedBy === data?.operatorId
              const promotion = a.kind === 'promote_admin'
              return (
                <tr key={a.approvalId}>
                  <td>
                    {approvalKindText[a.kind]}{promotion && a.targetOperatorEmail && <>: <strong>{a.targetOperatorEmail}</strong></>}
                    {a.counselReference && <> <Chip kind="neutral">counsel: {a.counselReference}</Chip></>}
                  </td>
                  <td>{mine ? 'you' : a.proposedByEmail}</td>
                  <td>{a.reason}</td>
                  <td><Time value={a.expiresAt} /></td>
                  <td>
                    {promotion ? (
                      mine ? (
                        <button type="button" className="secondary" onClick={() => setDecision({ decide: 'withdraw', approval: a })}>Withdraw…</button>
                      ) : (
                        <>
                          <button type="button" className="primary" onClick={() => setDecision({ decide: 'approve', approval: a })}>Approve…</button>{' '}
                          <button type="button" className="secondary" onClick={() => setDecision({ decide: 'reject', approval: a })}>Reject…</button>
                        </>
                      )
                    ) : (
                      <Link to={`/content/${a.caseId}`}>{mine ? 'Open case (waiting for someone else)' : 'Open case to decide'}</Link>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}
      {decision && (
        <ReasonDialog
          title={`${decision.decide === 'approve' ? 'Approve' : decision.decide === 'reject' ? 'Reject' : 'Withdraw'}: ${approvalKindText[decision.approval.kind]}`}
          confirmLabel={decision.decide === 'approve' ? 'Approve' : decision.decide === 'reject' ? 'Reject' : 'Withdraw'} danger={decision.decide === 'approve'}
          intro={<p>Proposed by {decision.approval.proposedByEmail}: {decision.approval.reason}. Both of you are recorded in the audit log.</p>}
          onSubmit={async (reason) => {
            await api('POST', `/approvals/${decision.approval.approvalId}/${decision.decide}`, { reason })
            setDecision(null)
            setNotice(decision.decide === 'approve' ? 'Approved. The step has been carried out.' : decision.decide === 'reject' ? 'Rejected.' : 'Withdrawn.')
            await reload()
          }}
          onClose={() => setDecision(null)}
        />
      )}
    </section>
  )
}
