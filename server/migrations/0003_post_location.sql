-- Optional coarse location for a post ("City, Country"), derived on-device from the
-- photo's GPS and reverse-geocoded there, so only the human-readable place — never raw
-- coordinates — reaches the server. Nullable; older clients simply omit it.
ALTER TABLE posts ADD COLUMN location TEXT;
