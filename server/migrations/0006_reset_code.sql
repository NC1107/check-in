-- Account recovery: the host issues a one-time reset code (relayed out-of-band, since
-- there's no email/SMS) that a member redeems to set a new password. Stored hashed,
-- short-lived, single-use.
ALTER TABLE users ADD COLUMN reset_code_hash    TEXT;
ALTER TABLE users ADD COLUMN reset_code_expires TIMESTAMPTZ;
