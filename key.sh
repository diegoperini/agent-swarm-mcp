#!/usr/bin/env bash
# Manage the access keys of the running remote swarm. Run it on the server, in
# this folder.
#
#   ./key.sh create "<description>"   new key, printed once   e.g. ./key.sh create "connector: claude.ai"
#   ./key.sh list
#   ./key.sh delete <key id>
#
# One key per user of the swarm (a Claude connector, your local swarm, ...),
# so you can revoke one without the others. A key signs in to the connector,
# to the web view, and lets a local swarm manage this one.
set -euo pipefail
cd "$(dirname "$0")"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
HOST="$(sed -n 's/^SWARM_PUBLIC_HOST=//p' config.env 2>/dev/null | tail -n 1 | tr -d '\r')"

case "${1:-}" in
  create|list|delete) ;;
  *) echo "usage: $0 create \"<description>\" | list | delete <key id>" >&2; exit 2 ;;
esac

"${DC[@]}" exec -T swarm sh -c 'umask 077 && exec pwsh -NoLogo -NoProfile -NonInteractive -File /app/mcp-server.ps1 key "$@"' key "$@"

if [ "$1" = create ] && [ -n "$HOST" ]; then
  cat <<MSG

Use it in one place only, and type it where it's asked for, never into a chat:
  Claude connector   URL https://${HOST}/mcp, then sign in with the key
  Local swarm        web view > Remote tab: address https://${HOST} and the key
  Web view           https://${HOST}/
MSG
fi
