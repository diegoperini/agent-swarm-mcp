#!/usr/bin/env bash
# Copy this folder to a server over SSH (rsync). Run it from this folder, for
# example in WSL:
#
#   REMOTE=ubuntu@swarm.example.com ./deploy.sh [path-to-ssh-private-key]
#
# REMOTE can be anything ssh accepts, including an alias from ~/.ssh/config.
# REMOTE_DIR is the folder on the server, relative to the login's home
# (default: agent-swarm-mcp). Then, on the server: cd ~/agent-swarm-mcp && ./run.sh
#
# Never sends or deletes server-side data or local secrets: .env, config.env,
# state/ and test/ are skipped, and --delete is deliberately not used.
set -euo pipefail
cd "$(dirname "$0")"

REMOTE="${REMOTE:-}"
REMOTE_DIR="${REMOTE_DIR:-agent-swarm-mcp}"
[ -n "$REMOTE" ] || { echo "usage: REMOTE=<user@host or ssh alias> $0 [path-to-ssh-private-key]" >&2; exit 2; }
SSH=(ssh); SSH_E="ssh"
if [ $# -ge 1 ]; then
  [ -f "$1" ] || { echo "error: private key not found: $1" >&2; exit 2; }
  SSH=(ssh -i "$1"); SSH_E="ssh -i '$1'"
fi

# Windows folders report every file as 777: --chmod normalises the modes, and
# the scripts get their executable bit back afterwards.
rsync -rltvz --chmod=D755,F644 -e "$SSH_E" \
  --exclude '.git/' \
  --exclude '.env' \
  --exclude 'config.env' \
  --exclude 'state/' \
  --exclude 'test/' \
  --exclude '*.tmp' \
  --exclude '*.lock' \
  ./ "$REMOTE:$REMOTE_DIR/"

"${SSH[@]}" "$REMOTE" "chmod 755 $REMOTE_DIR/run.sh $REMOTE_DIR/key.sh $REMOTE_DIR/deploy.sh"

echo "Deployed to $REMOTE:~/$REMOTE_DIR/"
echo "Next, on the server: cd ~/$REMOTE_DIR && ./run.sh   (the first time: cp config.env.example config.env and fill it in)"
