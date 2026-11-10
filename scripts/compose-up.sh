#!/usr/bin/env bash
# Start a stack with its secrets from Infisical.
#
# Usage: scripts/compose-up.sh <host>/<app> [extra `docker compose up` args]
#   e.g. scripts/compose-up.sh zoey/actual-budget --pull always
#
# 1. Logs in with this host's machine identity, from /etc/infisical/homelab.env
#    (INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, INFISICAL_PROJECT_ID).
# 2. Exports the Infisical folder /<app> (environment prod) to a temp file in memory.
# 3. Runs `docker compose up -d` with that file as the env file, so it's used for
#    ${VAR} substitution and by services with `env_file: ${INFISICAL_ENV_FILE:-.env}`.
# 4. Deletes the temp file. Containers keep their values after it's gone.
#
# Overrides: INFISICAL_CREDENTIALS (credentials file path), INFISICAL_ENV (env slug).
set -euo pipefail

die() { echo "compose-up: $*" >&2; exit 1; }

STACK="${1:-}"
[[ -n "$STACK" ]] || die "usage: compose-up.sh <host>/<app> [docker compose up args]"
shift
STACK="${STACK#./}"
STACK="${STACK%/}"
APP="$(basename "$STACK")"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="$REPO_ROOT/$STACK"
[[ -f "$STACK_DIR/compose.yaml" ]] || die "no compose.yaml in $STACK_DIR"

CREDS="${INFISICAL_CREDENTIALS:-/etc/infisical/homelab.env}"
[[ -r "$CREDS" ]] || die "can't read $CREDS"
# Sourced without export, so the client secret isn't passed on to docker compose.
# shellcheck source=/dev/null
. "$CREDS"
: "${INFISICAL_CLIENT_ID:?missing in $CREDS}"
: "${INFISICAL_CLIENT_SECRET:?missing in $CREDS}"
: "${INFISICAL_PROJECT_ID:?missing in $CREDS}"
ENV_SLUG="${INFISICAL_ENV:-prod}"

command -v infisical >/dev/null || die "infisical CLI not found on PATH"

TOKEN="$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --silent --plain)" || die "Infisical login failed"
[[ -n "$TOKEN" && "$TOKEN" != *[[:space:]]* ]] || die "Infisical login didn't return a token"

# Keep the exported secrets in RAM (tmpfs) and readable only by this user.
umask 077
SECRETS_FILE=""
for dir in "${XDG_RUNTIME_DIR:-}" /dev/shm "${TMPDIR:-/tmp}"; do
  [[ -n "$dir" ]] && SECRETS_FILE="$(mktemp "$dir/homelab-$APP.XXXXXX" 2>/dev/null)" && break
done
[[ -n "$SECRETS_FILE" ]] || die "couldn't create a temp file"
trap 'rm -f "$SECRETS_FILE"' EXIT

INFISICAL_TOKEN="$TOKEN" infisical export --format=dotenv \
  --env="$ENV_SLUG" --path="/$APP" --projectId="$INFISICAL_PROJECT_ID" \
  > "$SECRETS_FILE" || die "couldn't export /$APP from Infisical (does the folder exist?)"
[[ -s "$SECRETS_FILE" ]] || echo "compose-up: warning: /$APP has no secrets in Infisical" >&2

cd "$STACK_DIR"
INFISICAL_ENV_FILE="$SECRETS_FILE" docker compose --env-file "$SECRETS_FILE" up -d "$@"
