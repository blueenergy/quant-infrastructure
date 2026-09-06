#!/usr/bin/env python3
"""Send a DingTalk markdown alert when GitHub Actions CI fails.

Reads DATA_CONTRACT_WEBHOOK_URL (required to send) and optional
DATA_CONTRACT_WEBHOOK_SECRET (signed-robot mode) — same names as the
k8s data-contract alerter, so GitHub org secrets can reuse that robot.

CI_* environment variables are filled by .github/workflows/notify-dingtalk.yml.
Keep that workflow's embedded copy in sync with this file.

Exit 0 if the webhook is unset (so repos without secrets do not go extra-red)
or the message is accepted. Exit 1 if DingTalk rejects the body (errcode).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WEBHOOK_URL_ENV = "DATA_CONTRACT_WEBHOOK_URL"
WEBHOOK_SECRET_ENV = "DATA_CONTRACT_WEBHOOK_SECRET"
WEBHOOK_TIMEOUT_ENV = "DATA_CONTRACT_WEBHOOK_TIMEOUT"


def signed_url(url: str, secret: str, now_ms: int | None = None) -> str:
    """DingTalk optional signing mode; returns the URL unchanged without a secret."""
    if not secret or "oapi.dingtalk.com" not in url:
        return url
    timestamp = str(now_ms if now_ms is not None else round(time.time() * 1000))
    digest = hmac.new(
        secret.encode("utf-8"),
        f"{timestamp}\n{secret}".encode("utf-8"),
        hashlib.sha256,
    ).digest()
    sign = urllib.parse.quote_plus(base64.b64encode(digest))
    return f"{url}&timestamp={timestamp}&sign={sign}"


def failed_job_names(needs_json: str) -> list[str]:
    """Parse GitHub `toJSON(needs)` and return job ids whose result is failure."""
    try:
        needs = json.loads(needs_json or "{}")
    except json.JSONDecodeError:
        return []
    if not isinstance(needs, dict):
        return []
    names = []
    for name, spec in needs.items():
        if isinstance(spec, dict) and spec.get("result") == "failure":
            names.append(str(name))
    return names


def build_payload(
    repository: str,
    workflow: str,
    event: str,
    ref: str,
    sha: str,
    actor: str,
    run_url: str,
    failed_jobs: list[str],
) -> dict:
    subject = f"[CI] 失败 {repository}"
    sha7 = sha[:7] if sha else ""
    failed = ", ".join(failed_jobs) or "unknown"
    lines = [
        f"## {subject}",
        "",
        f"- workflow: {workflow}",
        f"- event: {event}",
        f"- branch: {ref}",
        f"- sha: `{sha7}`",
        f"- actor: {actor}",
        f"- failed jobs: **{failed}**",
    ]
    if run_url:
        lines.append(f"- [打开 Actions]({run_url})")
    return {"msgtype": "markdown", "markdown": {"title": subject, "text": "\n".join(lines)}}


def send(url: str, payload: dict, secret: str, timeout: float) -> dict:
    """POST markdown; raise RuntimeError on transport failure or non-zero errcode."""
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        signed_url(url, secret),
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {raw[:300]}") from exc
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-json response: {raw[:300]}") from exc
    errcode = parsed.get("errcode")
    if errcode:
        raise RuntimeError(f"errcode={errcode} errmsg={parsed.get('errmsg')!r}")
    return parsed


def main(env: dict | None = None) -> int:
    env = os.environ if env is None else env
    url = (env.get(WEBHOOK_URL_ENV) or "").strip()
    if not url:
        print(f"notify_ci_dingtalk: {WEBHOOK_URL_ENV} is not set; skip", file=sys.stderr)
        return 0
    payload = build_payload(
        repository=env.get("CI_REPOSITORY") or "",
        workflow=env.get("CI_WORKFLOW") or "",
        event=env.get("CI_EVENT") or "",
        ref=env.get("CI_REF") or "",
        sha=env.get("CI_SHA") or "",
        actor=env.get("CI_ACTOR") or "",
        run_url=env.get("CI_RUN_URL") or "",
        failed_jobs=failed_job_names(env.get("CI_NEEDS") or "{}"),
    )
    try:
        timeout = float(env.get(WEBHOOK_TIMEOUT_ENV) or "10")
        send(url, payload, (env.get(WEBHOOK_SECRET_ENV) or "").strip(), timeout)
    except Exception as exc:  # noqa: BLE001 — surface the reason, keep the original CI failure
        print(f"notify_ci_dingtalk: failed to send alert: {exc}", file=sys.stderr)
        return 1
    print(f"DingTalk CI alert sent: {payload['markdown']['title']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
