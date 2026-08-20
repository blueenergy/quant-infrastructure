#!/bin/bash
# Auto-deploy for quant-infrastructure (cron every 5 min).
# infra/ 与 apps/ 独立容错：一方 pull 卡住/失败不影响另一方部署。
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

log "New commit, pulling..."
if ! git pull 2>&1 >> "$LOG"; then
  log "ERROR: git pull failed — deploy skipped"
  exit 1
fi

# ---- infra（hermes/mongo/redis 等；Docker Hub 镜像可能卡住）----
if [ -d "$REPO/infra" ]; then
  cd "$REPO/infra" || exit 1
  log "Updating infra..."
  # NOTE: 不给 infra compose 传 --env-file：infra/.env 提供
  # HERMES_API_SERVER_KEY，传入 versions.env 会覆盖它导致 hermes 401。
  if timeout "$PULL_TIMEOUT" docker compose pull >>"$LOG" 2>&1; then
    if docker compose up -d --remove-orphans >>"$LOG" 2>&1; then
      log "infra deployed"
    else
      log "ERROR: infra compose up failed"
    fi
  else
    log "ERROR: infra compose pull timed out/failed — infra skipped, apps continue"
  fi
else
  log "ERROR: infra dir missing — infra skipped"
fi

# ---- apps（ACR 镜像；不因 infra 失败受影响）----
if [ -d "$REPO/apps" ]; then
  cd "$REPO/apps" || exit 1
  log "Updating apps..."
  if timeout "$PULL_TIMEOUT" docker compose --env-file versions.env pull >>"$LOG" 2>&1; then
    if docker compose --env-file versions.env up -d --remove-orphans >>"$LOG" 2>&1; then
      log "apps deployed"
    else
      log "ERROR: apps compose up failed"
    fi
  else
    log "ERROR: apps compose pull timed out/failed — apps skipped"
  fi
else
  log "ERROR: apps dir missing — apps skipped"
fi

log "Done"
