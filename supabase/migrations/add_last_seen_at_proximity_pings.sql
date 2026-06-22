-- Add last_seen_at to proximity_pings to persist the "currently hanging"
-- state across app restarts, preventing spurious re-pings after 5h together.
-- Nullable: existing rows and old app versions are unaffected.
ALTER TABLE proximity_pings ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;
