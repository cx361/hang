-- Add phone hash support for iPhone contact matching.
-- Idempotent migration so it can run safely in environments with partial setup.

ALTER TABLE IF EXISTS profiles
ADD COLUMN IF NOT EXISTS phone_hash TEXT;

CREATE INDEX IF NOT EXISTS idx_profiles_phone_hash
ON profiles(phone_hash);

CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_phone_hash
ON profiles(phone_hash)
WHERE phone_hash IS NOT NULL;
