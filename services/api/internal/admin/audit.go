package admin

import (
	"context"
	"encoding/json"
	"net"
	"time"

	"github.com/jackc/pgx/v5"
)

// AuditEntry is one row to append to operator_audit. The table accepts no UPDATE, DELETE or TRUNCATE.
type AuditEntry struct {
	OperatorID *string // nil when the CLI acted
	Actor      string  // e-mail of the operator, or "cli:<os user>"
	Action     string
	TargetType string
	TargetID   string
	Reason     string
	IP         string // already truncated, see TruncateIP
	Detail     map[string]any
}

// insertAudit appends an entry. Callers inside an action pass the action's transaction, so the action
// and its audit entry commit together; reads insert the entry before they return anything.
func insertAudit(ctx context.Context, q queryer, e AuditEntry) error {
	detail := e.Detail
	if detail == nil {
		detail = map[string]any{}
	}
	raw, err := json.Marshal(detail)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `INSERT INTO operator_audit(operator_id,actor,action,target_type,target_id,reason,ip,detail) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
		e.OperatorID, e.Actor, e.Action, e.TargetType, e.TargetID, e.Reason, e.IP, raw)
	return err
}

// TruncateIP keeps enough of an address to tell a VPN from somewhere else, and no more: IPv4 to its
// /24, IPv6 to its /48. An unparseable value becomes the empty string.
func TruncateIP(ip string) string {
	p := net.ParseIP(ip)
	if p == nil {
		return ""
	}
	if v4 := p.To4(); v4 != nil {
		return v4.Mask(net.CIDRMask(24, 32)).String() + "/24"
	}
	return p.Mask(net.CIDRMask(48, 128)).String() + "/48"
}

// AuditRecord is an entry as the audit endpoint returns it.
type AuditRecord struct {
	AuditID    int64          `json:"auditId"`
	At         time.Time      `json:"at"`
	OperatorID *string        `json:"operatorId"`
	Actor      string         `json:"actor"`
	Action     string         `json:"action"`
	TargetType string         `json:"targetType"`
	TargetID   string         `json:"targetId"`
	Reason     string         `json:"reason"`
	IP         string         `json:"ip"`
	Detail     map[string]any `json:"detail"`
}

// AuditFilter narrows the audit log. Before is the audit_id of the last row of the previous page.
type AuditFilter struct {
	OperatorID, Action, TargetID string
	Before                       int64
	Limit                        int
}

// ListAudit pages the log newest first, returning up to Limit+1 rows.
func (s *Service) ListAudit(ctx context.Context, f AuditFilter) ([]AuditRecord, error) {
	var operator, action, target any
	if f.OperatorID != "" {
		operator = f.OperatorID
	}
	if f.Action != "" {
		action = f.Action
	}
	if f.TargetID != "" {
		target = f.TargetID
	}
	rows, err := s.Pool.Query(ctx, `SELECT audit_id,at,operator_id::text,actor,action,target_type,target_id,reason,ip,detail
 FROM operator_audit
 WHERE ($1::uuid IS NULL OR operator_id=$1) AND ($2::text IS NULL OR action=$2) AND ($3::text IS NULL OR target_id=$3) AND ($4::bigint=0 OR audit_id<$4)
 ORDER BY audit_id DESC LIMIT $5`, operator, action, target, f.Before, f.Limit+1)
	if err != nil {
		return nil, err
	}
	recs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (AuditRecord, error) {
		var r AuditRecord
		var detail []byte
		if err := row.Scan(&r.AuditID, &r.At, &r.OperatorID, &r.Actor, &r.Action, &r.TargetType, &r.TargetID, &r.Reason, &r.IP, &detail); err != nil {
			return r, err
		}
		return r, json.Unmarshal(detail, &r.Detail)
	})
	if recs == nil && err == nil {
		recs = []AuditRecord{}
	}
	return recs, err
}

// PruneAudit deletes audit entries older than days (at least 365) through prune_operator_audit, which also
// records the prune. It is the only way an entry is ever removed.
func (s *Service) PruneAudit(ctx context.Context, p *Principal, reason string, days int) (int64, error) {
	var removed int64
	err := s.Pool.QueryRow(ctx, `SELECT prune_operator_audit($1,$2,$3,$4)`, p.Operator.ID, p.Operator.Email, reason, days).Scan(&removed)
	return removed, err
}
