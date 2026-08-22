#!/usr/bin/env bash
# ============================================================================
# bump-versions-env.sh — Bump apps/versions.env in quant-infrastructure with
# release notes in the commit message and apps/CHANGELOG.md.
#
# Called from app-repo CI after building an image. Requires a checkout of the
# app repo (fetch-depth: 0) and quant-infrastructure (path: infra).
#
# Required environment variables:
#   KEY           versions.env key, e.g. QUANT_API_IMAGE_TAG
#   TAG           new tag, e.g. sha-08e3406
#   DEPLOY_LABEL  short name for commit subject, e.g. quant-api
#   SOURCE_REPO   GitHub repo slug, e.g. blueenergy/quantFinance
#   NEW_SHA       full commit SHA being deployed (GITHUB_SHA)
#   APP_REPO_DIR  path to the checked-out app repository
#
# Optional:
#   SERVICES      comma-separated compose services rolled out, e.g.
#                 "quant-api, quant-scheduler"
#   MAX_COMMITS   max git log lines in notes (default: 30)
#   INFRA_DIR     infra checkout path (default: ./infra from cwd, or script parent)
# ============================================================================
set -euo pipefail

: "${KEY:?KEY is required (e.g. QUANT_API_IMAGE_TAG)}"
: "${TAG:?TAG is required (e.g. sha-08e3406)}"
: "${DEPLOY_LABEL:?DEPLOY_LABEL is required (e.g. quant-api)}"
: "${SOURCE_REPO:?SOURCE_REPO is required (e.g. blueenergy/quantFinance)}"
: "${NEW_SHA:?NEW_SHA is required (full GITHUB_SHA)}"
: "${APP_REPO_DIR:?APP_REPO_DIR is required (path to app repo checkout)}"

MAX_COMMITS="${MAX_COMMITS:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${INFRA_DIR:-}" ]; then
  INFRA_ROOT="$(cd "$INFRA_DIR" && pwd)"
else
  INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

VERSIONS_FILE="$INFRA_ROOT/apps/versions.env"
CHANGELOG_FILE="$INFRA_ROOT/apps/CHANGELOG.md"

NEW_SHA_SHORT="${NEW_SHA:0:7}"
NEW_TAG_SHA="${TAG#sha-}"

log() { echo "[bump-versions-env] $*"; }

require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

require_exists() {
  if [ ! -e "$1" ]; then
    echo "ERROR: required path not found: $1" >&2
    exit 1
  fi
}

require_file "$VERSIONS_FILE"
require_file "$CHANGELOG_FILE"
# `.git` is a directory in a normal checkout (including GitHub Actions).
# `-f` only matches a gitfile (worktrees) and was rejecting the common case,
# so every release job failed before bumping versions.env.
require_exists "$APP_REPO_DIR/.git"

read_old_tag() {
  grep -E "^${KEY}=" "$VERSIONS_FILE" | tail -1 | cut -d= -f2- || true
}

resolve_sha() {
  local ref="$1"
  git -C "$APP_REPO_DIR" rev-parse --verify "${ref}^{commit}" 2>/dev/null | cut -c1-7 || true
}

generate_changes() {
  local old_tag="$1"
  local -a lines=()
  local old_sha new_sha compare_base compare_head

  new_sha="$(resolve_sha "$NEW_SHA")"
  if [ -z "$new_sha" ]; then
    new_sha="$NEW_TAG_SHA"
  fi

  if [[ "$old_tag" =~ ^sha-[0-9a-f]+$ ]]; then
    old_sha="$(resolve_sha "${old_tag#sha-}")"
    if [ -n "$old_sha" ] && [ "$old_sha" != "$new_sha" ]; then
      compare_base="$old_sha"
      compare_head="$new_sha"
      mapfile -t lines < <(
        git -C "$APP_REPO_DIR" log \
          --format='- %s (%h)' \
          --max-count="$MAX_COMMITS" \
          "${old_sha}..${new_sha}" 2>/dev/null || true
      )
    fi
  fi

  if [ "${#lines[@]}" -eq 0 ]; then
    local subject
    subject="$(git -C "$APP_REPO_DIR" log -1 --format='%s' "$NEW_SHA" 2>/dev/null || true)"
    if [ -n "$subject" ]; then
      lines=("- ${subject} (${new_sha})")
    else
      lines=("- Deploy ${TAG}")
    fi
    compare_base="${compare_base:-$new_sha}"
    compare_head="$new_sha"
  fi

  COMPARE_URL="https://github.com/${SOURCE_REPO}/compare/${compare_base}...${compare_head}"
  CHANGES_TEXT="$(printf '%s\n' "${lines[@]}")"
}

prepend_changelog_entry() {
  local old_tag="$1"
  local date services_line entry tmp

  date="$(date -u +%Y-%m-%d)"
  services_line=""
  if [ -n "${SERVICES:-}" ]; then
    services_line="**Services:** ${SERVICES}"$'\n'
  fi

  entry=$(cat <<EOF

## ${DEPLOY_LABEL} — ${TAG} (${date})

**Source:** https://github.com/${SOURCE_REPO}/commit/${NEW_SHA}
${services_line}**Compare:** ${COMPARE_URL}
**Previous tag:** ${old_tag:-<none>}

${CHANGES_TEXT}

---
EOF
)

  tmp="$(mktemp)"
  head -n 5 "$CHANGELOG_FILE" > "$tmp"
  printf '%s' "$entry" >> "$tmp"
  tail -n +6 "$CHANGELOG_FILE" >> "$tmp"
  mv "$tmp" "$CHANGELOG_FILE"
}

write_commit_message() {
  local old_tag="$1"
  local msg_file services_line

  msg_file="$(mktemp)"
  services_line=""
  if [ -n "${SERVICES:-}" ]; then
    services_line="Services: ${SERVICES}"$'\n'
  fi

  cat > "$msg_file" <<EOF
deploy(${DEPLOY_LABEL}): ${TAG}

Source: ${SOURCE_REPO}@${NEW_SHA_SHORT}
Compare: ${COMPARE_URL}
${services_line}Changes since ${old_tag:-<none>}:
${CHANGES_TEXT}
EOF
  echo "$msg_file"
}

git -C "$INFRA_ROOT" config user.name "ci-bot"
git -C "$INFRA_ROOT" config user.email "ci-bot@users.noreply.github.com"

for attempt in 1 2 3 4 5; do
  git -C "$INFRA_ROOT" fetch --quiet origin main
  git -C "$INFRA_ROOT" reset --hard --quiet origin/main

  OLD_TAG="$(read_old_tag)"
  generate_changes "$OLD_TAG"

  sed -i "s|^${KEY}=.*|${KEY}=${TAG}|" "$VERSIONS_FILE"
  if git -C "$INFRA_ROOT" diff --quiet -- "$VERSIONS_FILE"; then
    log "versions.env already at ${TAG}; nothing to commit."
    exit 0
  fi

  prepend_changelog_entry "$OLD_TAG"
  COMMIT_MSG_FILE="$(write_commit_message "$OLD_TAG")"

  git -C "$INFRA_ROOT" add apps/versions.env apps/CHANGELOG.md
  git -C "$INFRA_ROOT" commit -F "$COMMIT_MSG_FILE"
  rm -f "$COMMIT_MSG_FILE"

  if git -C "$INFRA_ROOT" push origin main; then
    log "Pushed tag bump (${TAG}) with release notes."
    exit 0
  fi

  log "Push raced (attempt ${attempt}); retrying..."
  sleep $((attempt * 5))
done

echo "ERROR: failed to push tag bump after retries." >&2
exit 1
