#!/usr/bin/env bash
# Upload each stack's .env into the Infisical "homelab" project.
#
# Every <host>/<app>/.env is uploaded to the Infisical folder /<app>
# (e.g. zoey/actual-budget/.env -> /actual-budget). .env.example files are ignored.
#
# Run it on the server that holds the .env files, from anywhere inside the repo:
#   infisical login                 # once, as yourself (needs write access)
#   ./scripts/infisical-upload.sh --project-id <id> --dry-run
#   ./scripts/infisical-upload.sh --project-id <id>
#
# Options:
#   --project-id ID   Infisical project ID (or set INFISICAL_PROJECT_ID)
#   --env SLUG        Infisical environment slug (default: prod)
#   --dry-run         Show what would be uploaded (key names only), change nothing
#   -h, --help        Show this help
#   [host/app ...]    Only upload these stacks, e.g. zoey/immich rumi/arr
#
# Re-running is safe: secrets that already exist are updated.
# Keys with empty values are skipped (Infisical rejects them) and listed in the output.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

PROJECT_ID="${INFISICAL_PROJECT_ID:-}"
ENV_SLUG="prod"
DRY_RUN=false
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:?--project-id needs a value}"; shift 2 ;;
    --env)        ENV_SLUG="${2:?--env needs a value}"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)            TARGETS+=("${1%/}"); shift ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Missing project ID: pass --project-id or set INFISICAL_PROJECT_ID." >&2
  exit 2
fi

# Collect .env files: either the stacks given on the command line, or every <host>/<app>/.env.
ENV_FILES=()
if [[ ${#TARGETS[@]} -gt 0 ]]; then
  for t in "${TARGETS[@]}"; do
    if [[ -f "$t/.env" ]]; then
      ENV_FILES+=("$t/.env")
    else
      echo "No .env found at $t/.env" >&2
      exit 1
    fi
  done
else
  shopt -s nullglob
  ENV_FILES=(*/*/.env)
  shopt -u nullglob
fi

if [[ ${#ENV_FILES[@]} -eq 0 ]]; then
  echo "No .env files found under $REPO_ROOT." >&2
  exit 0
fi

# Folders are flat (/<app>), so two hosts with the same app name would collide.
declare -A SEEN=()
for f in "${ENV_FILES[@]}"; do
  app="$(basename "$(dirname "$f")")"
  if [[ -n "${SEEN[$app]:-}" ]]; then
    echo "Folder name clash: ${SEEN[$app]} and $f both map to /$app." >&2
    exit 1
  fi
  SEEN[$app]="$f"
done

# Print the key names in a .env (never the values).
env_keys() {
  grep -Ev '^[[:space:]]*(#|//|$)' "$1" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/[[:space:]]*=.*$//' \
    | tr '\n' ' ' || true
}

# Infisical refuses secrets with empty values (KEY=, KEY="", KEY=''), so those are skipped.
# mode=keys prints the empty keys' names; mode=filter prints the file without those lines.
empty_value_awk() {
  awk -v mode="$1" '
    match($0, /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*/) {
      rest = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", rest)
      if (rest == "" || rest == "\"\"" || rest == "\047\047") {
        if (mode == "keys") { key = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", key); sub(/[[:space:]]*=.*$/, "", key); printf "%s ", key }
        next
      }
    }
    mode == "filter" { print }
  ' "$2"
}

TMP_FILE="$(mktemp)"
chmod 600 "$TMP_FILE"
trap 'rm -f "$TMP_FILE"' EXIT

CLI=""
if ! $DRY_RUN; then
  command -v infisical >/dev/null || { echo "infisical CLI not found on PATH." >&2; exit 1; }

  # Newer CLIs moved these commands under `secrets-manager`; older ones use `secrets`.
  if infisical secrets-manager --help >/dev/null 2>&1; then
    CLI=new
  else
    CLI=legacy
  fi
fi

COMMON=(--env="$ENV_SLUG" --projectId="$PROJECT_ID" --silent)

create_folder() {
  local app="$1" out
  if [[ $CLI == new ]]; then
    out="$(infisical secrets-manager folders create "$app" --path=/ "${COMMON[@]}" 2>&1)" && return 0
  else
    out="$(infisical secrets folders create --name="$app" --path=/ "${COMMON[@]}" 2>&1)" && return 0
  fi
  # An existing folder is fine; anything else is a real error.
  if grep -qi 'exist' <<<"$out"; then return 0; fi
  echo "$out" >&2
  return 1
}

upload_file() {
  local file="$1" app="$2"
  if [[ $CLI == new ]]; then
    # `create` refuses existing secrets, so fall back to `update` on re-runs.
    infisical secrets-manager secrets create --file="$file" --path="/$app" "${COMMON[@]}" >/dev/null 2>&1 \
      || infisical secrets-manager secrets update --file="$file" --path="/$app" "${COMMON[@]}" >/dev/null
  else
    # Legacy `secrets set` creates or updates.
    infisical secrets set --file="$file" --path="/$app" "${COMMON[@]}" >/dev/null
  fi
}

echo "Project $PROJECT_ID, environment '$ENV_SLUG'$($DRY_RUN && echo ' (dry run)')"
FAILED=()
for f in "${ENV_FILES[@]}"; do
  app="$(basename "$(dirname "$f")")"
  echo "  $f -> /$app"
  echo "      keys: $(env_keys "$f")"
  skipped="$(empty_value_awk keys "$f")"
  [[ -n "$skipped" ]] && echo "      skipped (empty value): $skipped"
  $DRY_RUN && continue

  empty_value_awk filter "$f" > "$TMP_FILE"
  if [[ -z "$(env_keys "$TMP_FILE")" ]]; then
    echo "      nothing to upload (all values empty)"
    continue
  fi

  if create_folder "$app" && upload_file "$TMP_FILE" "$app"; then
    echo "      uploaded"
  else
    echo "      FAILED" >&2
    FAILED+=("$f")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "" >&2
  echo "Failed: ${FAILED[*]}" >&2
  echo "See the infisical error above each FAILED line. A file with a mix of new and" >&2
  echo "existing keys can be refused by both create and update; check that folder in the UI." >&2
  exit 1
fi

$DRY_RUN || echo "Done. Check the values in the Infisical UI before deleting any .env files."
