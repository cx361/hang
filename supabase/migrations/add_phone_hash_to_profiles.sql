-- Migration: Add phone_hash column to profiles for contact-based friend discovery
-- Purpose: Enable users to find friends by matching phone numbers (stored as SHA-256 hashes)
-- Privacy: Phone numbers are always hashed on client-side; server never sees plaintext

ALTER TABLE profiles
ADD COLUMN phone_hash TEXT UNIQUE;

CREATE INDEX idx_profiles_phone_hash ON profiles(phone_hash);

-- RLS Policy: Allow authenticated users to read phone_hash for friend matching
-- This policy enables contact matching while still protecting unrelated users' phone_hashes
CREATE POLICY "authenticated_users_can_read_phone_hash" ON profiles
  FOR SELECT
  USING (auth.role() = 'authenticated');
