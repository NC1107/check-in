#!/usr/bin/env bash
# new-group.sh — provision a new friend group on this host.
#
#   ./scripts/new-group.sh <slug> "Display Name"
#
# What it does:
#   1. writes groups/<slug>.env (the registry entry)
#   2. creates the group's database (checkin_<slug>) if the db container is running
#   3. re-renders docker-compose.generated.yml + Caddyfile.generated + static assets
#   4. brings the stack up (the new server migrates its empty database on boot)
#
# Prereqs: DNS for <slug>.$CHECKIN_DOMAIN pointing at this host (a wildcard record
# covers all future groups), and the usual .env next to docker-compose.yml.

set -euo pipefail

cd "$(dirname "$0")/.."

slug="${1:-}"
name="${2:-}"

if [ -z "$slug" ] || [ -z "$name" ]; then
  echo "usage: $0 <slug> \"Display Name\"" >&2
  exit 1
fi
if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "error: slug must be lowercase letters, digits, hyphens" >&2
  exit 1
fi
if [ "$slug" = "main" ]; then
  echo "error: 'main' is reserved for the original group" >&2
  exit 1
fi
if [ -e "groups/$slug.env" ]; then
  echo "error: groups/$slug.env already exists" >&2
  exit 1
fi

mkdir -p groups
debug_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "groups/$slug.env" <<EOF
SLUG=$slug
DISPLAY_NAME="$name"
CHECKIN_DEBUG_TOKEN=$debug_token
EOF
echo "registered groups/$slug.env"

# Create the database now if the stack is already running; otherwise it must be created
# before first boot of the new server (the server migrates schemas, not databases).
compose_file=docker-compose.generated.yml
[ -f "$compose_file" ] || compose_file=docker-compose.yml
if docker compose -f "$compose_file" ps db --status running 2>/dev/null | grep -q db; then
  docker compose -f "$compose_file" exec -T db \
    createdb -U "${POSTGRES_USER:-checkin}" "checkin_$slug" \
    && echo "created database checkin_$slug" \
    || echo "note: createdb failed (database may already exist)"
else
  echo "note: db container not running — create the database before/with first start:"
  echo "  docker compose -f docker-compose.generated.yml up -d db"
  echo "  docker compose -f docker-compose.generated.yml exec db createdb -U checkin checkin_$slug"
fi

./scripts/gen-stack.sh

echo
echo "next:"
echo "  docker compose -f docker-compose.generated.yml up -d"
echo
echo "then IMPORTANT — before sharing any invite link:"
echo "  sign up on https://$slug.\$CHECKIN_DOMAIN yourself NOW."
echo "  The FIRST signup on a fresh group becomes its admin; a friend who opens the"
echo "  invite first would own the group instead of you."
echo
echo "invite link (after you've claimed admin): https://$slug.\$CHECKIN_DOMAIN/join"
