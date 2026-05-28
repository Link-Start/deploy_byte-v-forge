CREATE TABLE IF NOT EXISTS mailbox_operations (
  operation_id text PRIMARY KEY,
  action text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT '',
  email_address text NOT NULL DEFAULT '',
  last_step text NOT NULL DEFAULT '',
  error_message text NOT NULL DEFAULT '',
  import_only boolean NOT NULL DEFAULT false,
  only_missing boolean NOT NULL DEFAULT false,
  "limit" integer NOT NULL DEFAULT 0,
  claim_owner text NOT NULL DEFAULT '',
  claim_until bigint NOT NULL DEFAULT 0,
  attempt_count integer NOT NULL DEFAULT 0,
  exit_code integer NOT NULL DEFAULT 0,
  mailbox_count integer NOT NULL DEFAULT 0,
  fetched_count integer NOT NULL DEFAULT 0,
  failed_count integer NOT NULL DEFAULT 0,
  message_count integer NOT NULL DEFAULT 0,
  created_at bigint NOT NULL DEFAULT 0,
  updated_at bigint NOT NULL DEFAULT 0
);
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS import_only boolean NOT NULL DEFAULT false;
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS only_missing boolean NOT NULL DEFAULT false;
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS "limit" integer NOT NULL DEFAULT 0;
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS claim_owner text NOT NULL DEFAULT '';
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS claim_until bigint NOT NULL DEFAULT 0;
ALTER TABLE mailbox_operations ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_mailbox_operations_action ON mailbox_operations(action);
CREATE INDEX IF NOT EXISTS idx_mailbox_operations_status ON mailbox_operations(status);
CREATE INDEX IF NOT EXISTS idx_mailbox_operations_email_address ON mailbox_operations(email_address);
CREATE INDEX IF NOT EXISTS idx_mailbox_operations_claim_owner ON mailbox_operations(claim_owner);
CREATE INDEX IF NOT EXISTS idx_mailbox_operations_claim_until ON mailbox_operations(claim_until);
CREATE TABLE IF NOT EXISTS mailbox_platform_event_outbox (event_id TEXT PRIMARY KEY, subject TEXT NOT NULL, event_name TEXT NOT NULL, idempotency_key TEXT NOT NULL DEFAULT '', envelope BYTEA NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING', attempt_count INT NOT NULL DEFAULT 0, next_attempt_at BIGINT NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '', published_at BIGINT NOT NULL DEFAULT 0, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_mailbox_platform_event_outbox_pending ON mailbox_platform_event_outbox(status, next_attempt_at, created_at);
