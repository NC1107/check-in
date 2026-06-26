-- Throttle reset-code brute force. A host-issued code is only 8 chars, so without a cap
-- a distributed attacker could guess it within its validity window. Lock the code after
-- too many wrong redeem attempts (the host simply re-issues a fresh one).
ALTER TABLE users ADD COLUMN reset_code_attempts INT NOT NULL DEFAULT 0;
