#!/usr/bin/env bash
#
# Block until an image tag is actually readable on Aliyun ACR.
#
# Call this from an app repo's release job BEFORE bumping apps/versions.env.
# CI publishes to ghcr only; host/mirror_to_acr.sh on the WSL box relays each
# new sha-* tag into ACR. The deploy targets pull from ACR, so bumping before
# the relay has landed would dispatch a deploy that dies on `docker compose
# pull` and takes three more attempts down with it.
#
# Failing here is the point. A relay that has stopped working must surface as a
# red release job and a DingTalk alert -- the failure this whole arrangement
# replaces was one that stayed green and silent for 3.5 hours. See llm-wiki:
#   projects/trading/repos/stock-scoring-system/ci-acr-push-silent-hang
#
# Required env:
#   ACR_REGISTRY  e.g. crpi-xxxx.cn-hangzhou.personal.cr.aliyuncs.com
#   ACR_REPO      e.g. wukongquant/quant-scorer
#   TAG           e.g. sha-10fd655
#   ALIYUN_USER / ALIYUN_TOKEN
# Optional:
#   TIMEOUT   seconds to wait (default 2700)
#   INTERVAL  seconds between checks (default 30)

set -euo pipefail

ACR_REGISTRY=${ACR_REGISTRY:?ACR_REGISTRY is required}
ACR_REPO=${ACR_REPO:?ACR_REPO is required}
TAG=${TAG:?TAG is required}
ALIYUN_USER=${ALIYUN_USER:?ALIYUN_USER is required}
ALIYUN_TOKEN=${ALIYUN_TOKEN:?ALIYUN_TOKEN is required}
TIMEOUT=${TIMEOUT:-2700}
INTERVAL=${INTERVAL:-30}

# ACR answers /v2/ with a 401 that names its token service; the docker CLI does
# this dance internally. Doing it here keeps docker (and buildx) out of the
# loop entirely -- the whole point is that this check must not be able to hang
# the way a buildx registry operation can.
MANIFEST_ACCEPT='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

fetch_token() {
  local challenge realm service
  challenge=$(curl -sSI -u "$ALIYUN_USER:$ALIYUN_TOKEN" "https://$ACR_REGISTRY/v2/" \
    | tr -d '\r' | grep -i '^www-authenticate:' | head -1)
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
  if [ -z "$realm" ]; then
    echo "::error::no auth realm in the response from $ACR_REGISTRY -- are ALIYUN_USER/ALIYUN_TOKEN valid?"
    return 1
  fi
  curl -fsS -u "$ALIYUN_USER:$ALIYUN_TOKEN" \
    "$realm?service=$service&scope=repository:$ACR_REPO:pull" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))'
}

manifest_status() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $1" -H "Accept: $MANIFEST_ACCEPT" \
    "https://$ACR_REGISTRY/v2/$ACR_REPO/manifests/$TAG"
}

echo "Waiting up to ${TIMEOUT}s for $ACR_REPO:$TAG on $ACR_REGISTRY"
TOKEN=$(fetch_token)
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while :; do
  code=$(manifest_status "$TOKEN") || code=000

  if [ "$code" = "200" ]; then
    echo "OK: $ACR_REPO:$TAG is on ACR"
    exit 0
  fi
  # The token is short-lived; a 401 mid-wait is a stale token, not a missing
  # tag, so refresh and keep going rather than counting it as progress.
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then
    TOKEN=$(fetch_token)
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::$ACR_REPO:$TAG did not reach ACR within ${TIMEOUT}s (last HTTP $code). The ghcr->ACR relay on the host has probably stopped -- check host/mirror_to_acr.log."
    exit 1
  fi

  echo "  ... not there yet (HTTP $code), retrying in ${INTERVAL}s"
  sleep "$INTERVAL"
done
