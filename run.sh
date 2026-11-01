#!/usr/bin/env bash
# Build and (re)start the remote agent swarm. Run it on the server, in this
# folder, as the user that owns it:   ./run.sh
#
# Keeps everything in ./state (conversations, archive, access keys, connector
# sign-ins), so running it again is safe: agents that were working resume.
# Settings: ./config.env (copy config.env.example).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f config.env ]; then
  echo "error: config.env is missing. Copy config.env.example to config.env and fill it in." >&2
  exit 1
fi
set -a; . ./config.env; set +a

[ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "error: ANTHROPIC_API_KEY is empty in config.env." >&2; exit 1; }
if [ -z "${SWARM_PUBLIC_HOST:-}" ] || [ "$SWARM_PUBLIC_HOST" = swarm.example.com ]; then
  echo "error: set SWARM_PUBLIC_HOST in config.env to this server's host name." >&2; exit 1
fi
case "$SWARM_PUBLIC_HOST" in
  *://*|*/*) echo "error: SWARM_PUBLIC_HOST is a host name only, without https:// or a path." >&2; exit 1 ;;
esac
export SWARM_PUBLIC_HOST
export SWARM_PUBLIC_URL="https://${SWARM_PUBLIC_HOST}"
export SWARM_INSTANCE_NAME="${SWARM_INSTANCE_NAME:-remote}"
export HOST_UID="$(id -u)" HOST_GID="$(id -g)"
export DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1

FILES=(-f docker-compose.yml)
if [ -n "${SWARM_CADDY_NETWORK:-}" ]; then
  export SWARM_CADDY_NETWORK
  FILES+=(-f docker-compose.shared-caddy.yml)
  if ! docker network inspect "$SWARM_CADDY_NETWORK" >/dev/null 2>&1; then
    echo "error: Docker network '$SWARM_CADDY_NETWORK' (SWARM_CADDY_NETWORK) doesn't exist. Is your Caddy running on it?" >&2
    exit 1
  fi
else
  FILES+=(-f docker-compose.bundled-caddy.yml)
fi

if docker compose version >/dev/null 2>&1; then DC=(docker compose "${FILES[@]}")
elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose "${FILES[@]}")
else echo "error: docker compose not found (install the Compose plugin)." >&2; exit 1; fi

# The bundled Caddy needs port 443, unless it is the one already holding it.
if [ -z "${SWARM_CADDY_NETWORK:-}" ]; then
  holder="$(docker ps --filter publish=443 --format '{{.Names}}' 2>/dev/null | grep -v '^agent-swarm-caddy$' || true)"
  if [ -n "$holder" ]; then
    echo "error: port 443 is already published by the container(s): $holder" >&2
    echo "If that is a Caddy, set SWARM_CADDY_NETWORK in config.env to its Docker network instead." >&2
    exit 1
  fi
  if command -v ss >/dev/null 2>&1 && [ -z "$(docker ps -q --filter name='^agent-swarm-caddy$')" ] && [ -n "$(ss -Hltn 'sport = :443' 2>/dev/null)" ]; then
    echo "error: port 443 is in use on this host (not by Docker). Free it, or put the swarm behind that server with SWARM_CADDY_NETWORK." >&2
    exit 1
  fi
fi

mkdir -p state
if [ ! -w state ]; then
  echo "error: ./state isn't writable by $(id -un). Fix its owner (sudo chown -R $(id -u):$(id -g) state)." >&2
  exit 1
fi

echo "==> Building and starting"
"${DC[@]}" up -d --build --remove-orphans

echo -n "==> Waiting for the swarm"
ok=
for _ in $(seq 1 60); do
  if "${DC[@]}" exec -T swarm curl -fsS http://127.0.0.1:8780/_health >/dev/null 2>&1; then ok=1; break; fi
  echo -n "."; sleep 1
done
echo
if [ -z "$ok" ]; then
  echo "error: the swarm didn't start; its log:" >&2
  "${DC[@]}" logs --tail 60 swarm >&2
  exit 1
fi

KEYS="$("${DC[@]}" exec -T swarm pwsh -NoLogo -NoProfile -NonInteractive -File /app/mcp-server.ps1 key list 2>&1 | tr -d '\r')"

cat <<MSG

agent-swarm ($SWARM_INSTANCE_NAME) is up.

  Web view     ${SWARM_PUBLIC_URL}/
  Connector    ${SWARM_PUBLIC_URL}/mcp   (Claude custom connector; sign in with an access key)
  Local swarm  web view > Remote tab: address ${SWARM_PUBLIC_URL} and an access key
  Log          ${DC[*]} logs -f swarm

Access keys (./state/keys.json):
${KEYS}

Create a key:  ./key.sh create "<description>"     (shown once)
MSG

if [ -n "${SWARM_CADDY_NETWORK:-}" ]; then
  cat <<MSG

HTTPS comes from your Caddy on the '$SWARM_CADDY_NETWORK' network. If it doesn't
serve ${SWARM_PUBLIC_HOST} yet, add this site block and reload it:

${SWARM_PUBLIC_HOST} {
	tls {
		issuer acme {
			disable_http_challenge
		}
	}
	reverse_proxy http://agent-swarm:8780 {
		flush_interval -1
	}
}
MSG
else
  cat <<MSG

HTTPS: the bundled Caddy gets a Let's Encrypt certificate for ${SWARM_PUBLIC_HOST}
over port 443 within a minute. Follow it with: ${DC[*]} logs -f caddy
(it says "certificate obtained successfully"). It needs DNS pointing here and
443/tcp open to the internet.
MSG
fi
