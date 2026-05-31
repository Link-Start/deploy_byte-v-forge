CREATE TABLE IF NOT EXISTS gopay_account_profiles (
  gopay_account_id text PRIMARY KEY,
  wa_phone text NOT NULL DEFAULT '',
  created_at bigint NOT NULL DEFAULT 0,
  updated_at bigint NOT NULL DEFAULT 0
);

ALTER TABLE gopay_account_profiles DROP COLUMN IF EXISTS pin;
