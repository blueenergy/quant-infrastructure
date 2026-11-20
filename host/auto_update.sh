#!/bin/bash
# Auto-deploy for quant-infrastructure (cron every 5 min).
# infra/ 与 apps/ 独立容错：一方 pull 卡住/失败不影响另一方部署。
#
# 2026-11-20: only the subtree that changed is deployed.  Before this, every
# app bump ran `docker compose pull` over the whole infra stack too, so a
# republished `mongo:7.0` tag recreated the database during an unrelated app
# release (11 times since 2026-08-21).  See
# llm-wiki projects/trading/ops/mongo-floating-tag-recreate-20261120.md.
REPO=/home/shuyolin/trading/quant-infrastructure
LOG=$REPO/auto_update.log
LOCK=/tmp/auto_update.lock
PULL_TIMEOUT=300   # 单个 compose pull 的最长等待秒数

log() { echo "[$(date)] $*" >> "$LOG"; }

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "Another auto_update run is active; skipping."
    exit 0
  fi
fi

cd "$REPO" || { log "ERROR: repo $REPO missing"; exit 1; }
git fetch origin 2>>"$LOG"
LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse "origin/$(git branch --show-current)" 2>/dev/null)

if [ -z "$REMOTE" ] || [ "$LOCAL" = "$REMOTE" ]; then
  log "No changes"
  exit 0
fi

BEFORE=$(git rev-parse HEAD 2>/dev/null)
log "New commit, pulling..."
# Redirect order matters: `>> "$LOG" 2>&1` sends BOTH streams to the log.
# Written the other way round (`2>&1 >> "$LOG"`), stderr binds to the original
# stdout first and the real git error never reaches the log -- cron has no
# redirection either, so a failed pull left no trace of why (2026-10-07).
if ! git pull >>"$LOG" 2>&1; then
  log "ERROR: git pull failed — deploy skipped"
  exit 1
fi
AFTER=$(git rev-parse HEAD 2>/dev/null)
CHANGED=$(git diff --name-only "$BEFORE" "$AFTER" 2>/dev/null || true)
log "Changed paths: $(printf '%s\n' "$CHANGED" | sed '/^$/d' | tr '\n' ' ')"

RUN_INFRA=0
RUN_APPS=0
if printf '%s\n' "$CHANGED" | grep -q '^infra/'; then RUN_INFRA=1; fi
if printf '%s\n' "$CHANGED" | grep -q '^apps/'; then RUN_APPS=1; fi

if [ "$RUN_INFRA" -eq 0 ] && [ "$RUN_APPS" -eq 0 ]; then
  log "No apps/infra changes — nothing to deploy"
  exit 0
fi

# Map the changed `*_IMAGE_TAG` keys in apps/versions.env to every compose
# service that consumes that image.  Shared images are expanded (e.g.
# QUANT_API_IMAGE_TAG -> quant-api + quant-mcp-* + quant-scheduler), so a
# targeted roll still updates all replicas of the same release.
derive_app_services() {
  local before="$1" after="$2"
  local keys
  keys=$(git diff -U0 "$before" "$after" -- apps/versions.env 2>/dev/null \
    | sed -n 's/^[-+]\([A-Z0-9_]*_IMAGE_TAG\)=.*/\1/p' | sort -u)
  [ -z "$keys" ] && return 0
  local svc key
  while read -r svc key; do
    if printf '%s\n' "$keys" | grep -qx "$key"; then
      printf '%s\n' "$svc"
    fi
  done < <(awk '
    /^  [a-z0-9-]+:[[:space:]]*$/ { svc=$1; sub(":", "", svc); next }
    /^    image:.*\$\{[A-Z0-9_]+_IMAGE_TAG/ {
      match($0, /\$\{[A-Z0-9_]+_IMAGE_TAG/)
      print svc, substr($0, RSTART+2, RLENGTH-2)
    }
  ' apps/docker-compose.yml) | sort -u | tr '\n' ' '
}

APP_SERVICES=""
if [ "$RUN_APPS" -eq 1 ]; then
  APP_SERVICES=$(derive_app_services "$BEFORE" "$AFTER")
fi

# ---- infra（hermes/mongo 等；Docker Hub 镜像可能卡住）----
if [ "$RUN_INFRA" -eq 1 ]; then
  if [ -d "$REPO/infra" ]; then
    cd "$REPO/infra" || exit 1
    log "Updating infra..."
    # NOTE: 不给 infra compose 传 --env-file：infra/.env 提供
    # HERMES_API_SERVER_KEY，传入 versions.env 会覆盖它导致 hermes 401。
    # pull 失败不阻断 up：本地已有镜像（如 hermes digest）时 up 无需联网。
    timeout "$PULL_TIMEOUT" docker compose pull >>"$LOG" 2>&1 \
      || log "WARN: infra compose pull timed out/failed — falling back to local images"
    if docker compose up -d --remove-orphans >>"$LOG" 2>&1; then
      log "infra deployed"
    else
      log "ERROR: infra compose up failed"
    fi
  else
    log "ERROR: infra dir missing — infra skipped"
  fi
else
  log "infra unchanged — skipped"
fi

# ---- apps（ACR 镜像；走 deploy.sh 与火山云 CD 一致：带 pre/post hooks、
#      profiles 过滤、--wait 健康检查；不因 infra 失败受影响）----
if [ "$RUN_APPS" -eq 1 ]; then
  if [ -d "$REPO/apps" ]; then
    cd "$REPO/apps" || exit 1
    if [ -n "$APP_SERVICES" ]; then
      log "Updating apps (targeted: $APP_SERVICES)..."
      # deploy.sh 内部已含 pull（含超时控制的 hook 内 pull），这里只做整体兜底超时。
      if timeout 900 ./deploy.sh $APP_SERVICES >>"$LOG" 2>&1; then
        log "apps deployed"
      else
        log "WARN: targeted apps deploy failed — retrying full apps deploy"
        if timeout 900 ./deploy.sh >>"$LOG" 2>&1; then
          log "apps deployed (full fallback)"
        else
          log "ERROR: apps deploy failed (deploy.sh exit != 0)"
        fi
      fi
    else
      log "Updating apps (full: no image-tag change detected)..."
      if timeout 900 ./deploy.sh >>"$LOG" 2>&1; then
        log "apps deployed"
      else
        log "ERROR: apps deploy failed (deploy.sh exit != 0)"
      fi
    fi
  else
    log "ERROR: apps dir missing — apps skipped"
  fi
else
  log "apps unchanged — skipped"
fi

log "Done"
