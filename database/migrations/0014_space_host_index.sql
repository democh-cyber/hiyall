-- Host limits must probe the host's own index range, never the global table.
CREATE INDEX spaces_host_open ON spaces(owner_id,ends_at) WHERE status='open';
