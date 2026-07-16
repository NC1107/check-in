-- The key this server was issued when it registered with the push relay. Persisted so the
-- server registers exactly once (on its first boot in relay mode) and reuses the same key
-- across restarts. Empty until then. Only meaningful when the server forwards push through
-- the relay rather than talking to FCM directly.
ALTER TABLE server_config ADD COLUMN relay_key TEXT NOT NULL DEFAULT '';
