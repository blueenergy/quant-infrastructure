#!/usr/bin/env python3
"""一次性查看本机 LLM 额度：Ark key 池（ccp）+ MiniMax Token Plan（ccm）
+ 百炼 Token Plan（ccb）。

用法:
    llm-status              # 全部查
    llm-status --ark        # 只看 Ark key 池
    llm-status --minimax    # 只看 MiniMax Token Plan
    llm-status --bailian    # 只看百炼 Token Plan
    llm-status --raw        # 原始 JSON

退出码: 0 查询都成功 / 1 至少一块查询失败（配置缺失也算失败）。
        百炼返回 hasQuotaData=false 视为「套餐异常」提示，不算查询失败。
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.request

ARK_CONFIG = pathlib.Path.home() / ".config/ark-proxy" / "config.json"
ARK_STATUS_URL = "http://127.0.0.1:8787/status"
MINIMAX_PROFILE = pathlib.Path.home() / ".claude/profiles" / "minimax.json"
MINIMAX_URL = "https://api.minimax.io/v1/token_plan/remains"
BAILIAN_CMD = ("bl", "usage", "token-plan", "--output", "json")


# --------------------------------------------------------------------------
# 格式化
# --------------------------------------------------------------------------
def display_width(text: str) -> int:
    """按终端显示宽度计算（CJK 全角字符占 2 列）。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def pad(text: str, width: int) -> str:
    return text + " " * max(0, width - display_width(text))


def fmt_time(ts: int, now: dt.datetime, unit: str = "s") -> str:
    """unix 时间戳 -> 11-27 23:59；跨年时带上年份。unit='ms' 时按毫秒处理。"""
    if not ts:
        return "-"
    seconds = ts / 1000 if unit == "ms" else ts
    when = dt.datetime.fromtimestamp(seconds)
    fmt = "%Y-%m-%d %H:%M" if when.year != now.year else "%m-%d %H:%M"
    return when.strftime(fmt)


def fmt_left(seconds: float) -> str:
    if seconds <= 0:
        return "已到期"
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days}d{hours:02d}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def print_table(headers: list[str], rows: list[list[str]]) -> None:
    widths = [
        max(display_width(row[i]) for row in [headers, *rows])
        for i in range(len(headers))
    ]
    print("  ".join(pad(cell, widths[i]) for i, cell in enumerate(headers)).rstrip())
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(pad(cell, widths[i]) for i, cell in enumerate(row)).rstrip())


# --------------------------------------------------------------------------
# 取数
# --------------------------------------------------------------------------
def read_json(path: pathlib.Path) -> tuple[dict | None, str | None]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, f"找不到 {path}"
    except json.JSONDecodeError as exc:
        return None, f"{path} 不是合法 JSON: {exc}"


def http_json(request: urllib.request.Request, timeout: float) -> tuple[dict | None, str | None]:
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return None, "401 鉴权失败（key 不对或已失效）"
        body = exc.read().decode("utf-8", "replace")[:200]
        return None, f"HTTP {exc.code}: {body}"
    except urllib.error.URLError as exc:
        return None, f"连接失败: {exc.reason}"
    except TimeoutError:
        return None, "请求超时"


def fetch_ark() -> tuple[dict | None, str | None]:
    config, error = read_json(ARK_CONFIG)
    if error:
        return None, error
    token = str(config.get("local_token") or "").strip()
    if not token:
        return None, f"{ARK_CONFIG} 里没有 local_token"
    request = urllib.request.Request(
        ARK_STATUS_URL, headers={"Authorization": f"Bearer {token}"}
    )
    return http_json(request, timeout=5)


def fetch_minimax() -> tuple[dict | None, str | None]:
    profile, error = read_json(MINIMAX_PROFILE)
    if error:
        return None, error
    token = str((profile.get("env") or {}).get("ANTHROPIC_AUTH_TOKEN") or "").strip()
    if not token:
        return None, f"{MINIMAX_PROFILE} 里没有 ANTHROPIC_AUTH_TOKEN"
    request = urllib.request.Request(
        MINIMAX_URL,
        headers={"Authorization": f"Bearer {token}", "accept": "application/json"},
    )
    data, error = http_json(request, timeout=20)
    if error:
        return None, error
    # 该接口拒鉴权时也返回 HTTP 200，真正结果在 base_resp.status_code
    base = data.get("base_resp") or {}
    code = base.get("status_code")
    if code not in (0, None):
        return None, f"base_resp {code}: {base.get('status_msg')}"
    return data, None


def fetch_bailian() -> tuple[dict | None, str | None]:
    """调用 bl CLI；套餐正常时返回 perXxxPercentage/ResetTime，异常时只有 hasQuotaData=false。"""
    env = dict(os.environ)
    # bailian 协议要求脚本调用使用 script 归因
    env.setdefault("BAILIAN_CALLER_TYPE", "script")
    env.setdefault("BAILIAN_CALLER_NAME", "claude-code")
    try:
        proc = subprocess.run(
            BAILIAN_CMD, capture_output=True, text=True, timeout=30, env=env
        )
    except FileNotFoundError:
        return None, "找不到 bl 命令（npm install -g bailian-cli）"
    except subprocess.TimeoutExpired:
        return None, "bl usage token-plan 超时（30s）"

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        detail = (proc.stderr or proc.stdout).strip()[:200]
        return None, f"bl 输出不是 JSON（exit={proc.returncode}）: {detail}"

    if isinstance(data, dict) and data.get("error"):
        err = data["error"] or {}
        message = err.get("message") or "未知错误"
        hint = err.get("hint")
        return None, f"{message}" + (f"；{hint}" if hint else "")

    if proc.returncode != 0:
        return None, f"bl 退出码 {proc.returncode}: {(proc.stderr or '').strip()[:160]}"
    return data, None


# --------------------------------------------------------------------------
# 输出
# --------------------------------------------------------------------------
def render_ark(data: dict) -> None:
    now = dt.datetime.now()
    keys = data.get("keys", [])
    index_to_name = {i: k.get("name", "?") for i, k in enumerate(keys)}
    current = [
        f"{client}={index_to_name.get(index, index)}"
        for client, index in (data.get("current_by_client") or {}).items()
    ]

    print(f"== Ark key 池 (ark-proxy 127.0.0.1:8787) ==  now: {now:%Y-%m-%d %H:%M:%S}")
    print(f"sticky: {'  '.join(current) if current else '-'}")
    print()

    rows = []
    for key in keys:
        state = key.get("state", "?")
        rows.append(
            [
                key.get("name", "?"),
                state,
                key.get("kind") or "-",
                fmt_time(key.get("cooldown_until", 0), now) if state != "ok" else "-",
                fmt_left(key.get("cooldown_left", 0)) if state != "ok" else "-",
            ]
        )
    print_table(["KEY", "STATE", "KIND", "解冻时间", "剩余"], rows)

    usable = [k.get("name") for k in keys if k.get("state") == "ok"]
    print()
    if usable:
        print(f"可用 key: {len(usable)}/{len(keys)}  ({', '.join(usable)})")
    else:
        print(f"⚠️  没有可用 key：{len(keys)} 个都在冷却，ccp 会直接返回 503")


def render_minimax(data: dict) -> None:
    now = dt.datetime.now()
    print("== MiniMax Token Plan (ccm) ==  api.minimax.io/v1/token_plan/remains")
    print()

    rows = []
    for item in data.get("model_remains") or []:
        name = item.get("model_name", "?")
        # 只有本期和本周都标 3 才视为套餐未包含该池；1=正常、2=已用尽
        inactive = (
            item.get("current_interval_status") == 3
            and item.get("current_weekly_status") == 3
        )
        if inactive:
            name += " (未启用)"
        rows.append(
            [
                name,
                f"{item.get('current_interval_remaining_percent', '?')}%",
                fmt_time(item.get("end_time", 0), now, "ms"),
                fmt_left((item.get("remains_time") or 0) / 1000),
                f"{item.get('current_weekly_remaining_percent', '?')}%",
                fmt_time(item.get("weekly_end_time", 0), now, "ms"),
                fmt_left((item.get("weekly_remains_time") or 0) / 1000),
            ]
        )

    if not rows:
        print("⚠️  接口没有返回 model_remains")
        return
    print_table(["MODEL", "本期剩余", "本期结束", "本期倒计时", "本周剩余", "本周结束", "本周倒计时"], rows)
    print()
    print("提示: 百分比是「剩余」不是「已用」；本期窗口固定，充值/未用完都不结转")


PER_RE = re.compile(r"^per(\d+)(Hour|Day|Week|Month)(Percentage|ResetTime)$")
UNIT_HOURS = {"Hour": 1, "Day": 24, "Week": 168, "Month": 720}
UNIT_CN = {"Hour": "小时", "Day": "天", "Week": "周", "Month": "月"}


def bailian_windows(data: dict) -> list[dict]:
    """把 per5HourPercentage / per5HourResetTime 这类扁平字段还原成窗口列表。"""
    windows: dict[str, dict] = {}
    for field, value in data.items():
        match = PER_RE.match(field)
        if not match or not isinstance(value, (int, float)):
            continue
        count, unit, kind = match.groups()
        key = f"per{count}{unit}"
        item = windows.setdefault(
            key, {"count": int(count), "unit": unit, "percentage": None, "reset_ms": None}
        )
        if kind == "Percentage":
            item["percentage"] = float(value)
        else:
            item["reset_ms"] = value
    return sorted(
        windows.values(), key=lambda w: w["count"] * UNIT_HOURS.get(w["unit"], 0)
    )


def render_bailian(data: dict) -> None:
    now = dt.datetime.now()
    print("== 百炼 Token Plan (ccb/ccq) ==  bl usage token-plan")
    print()

    windows = bailian_windows(data)
    if not data.get("hasQuotaData") or not windows:
        print("⚠️  套餐异常：控制台没有返回额度数据（hasQuotaData=false）")
        print("    ccb/ccq 当前不可用，常见原因：")
        print("    - 套餐已过期或未续费")
        print("    - Console 登录的阿里云账号 ≠ 购买套餐的账号")
        print("    - key 已失效（模型端点会直接 403 AccessDenied.Unpurchased）")
        print("    排查: bl auth status / 百炼控制台 Token Plan 页面")
        return

    rows = []
    for window in windows:
        percentage = window["percentage"]
        reset_ms = window["reset_ms"]
        reset_text = "-"
        left_text = "-"
        if isinstance(reset_ms, (int, float)):
            reset_text = fmt_time(int(reset_ms), now, "ms")
            left_text = fmt_left((reset_ms - now.timestamp() * 1000) / 1000)
        label = f"{window['count']}{UNIT_CN.get(window['unit'], window['unit'])}"
        pct_text = f"{percentage * 100:.1f}%" if percentage is not None else "?"
        rows.append([label, pct_text, reset_text, left_text])
    print_table(["窗口", "剩余", "重置时间", "倒计时"], rows)


PROVIDERS = (
    ("ark", "Ark key 池", fetch_ark, render_ark),
    ("minimax", "MiniMax Token Plan", fetch_minimax, render_minimax),
    ("bailian", "百炼 Token Plan", fetch_bailian, render_bailian),
)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="查看本机 LLM 额度：Ark key 池 + MiniMax Token Plan + 百炼 Token Plan"
    )
    parser.add_argument("--ark", action="store_true", help="只看 Ark key 池")
    parser.add_argument("--minimax", action="store_true", help="只看 MiniMax Token Plan")
    parser.add_argument("--bailian", action="store_true", help="只看百炼 Token Plan")
    parser.add_argument("--raw", action="store_true", help="输出原始 JSON")
    args = parser.parse_args()

    selected = {"ark": args.ark, "minimax": args.minimax, "bailian": args.bailian}
    if not any(selected.values()):
        selected = {key: True for key in selected}

    result: dict[str, object] = {}
    failures = 0
    printed = False

    for key, title, fetch, render in PROVIDERS:
        if not selected[key]:
            continue
        data, error = fetch()
        result[key] = data if error is None else {"error": error}
        if error is None:
            if not args.raw:
                if printed:
                    print()
                render(data)
        else:
            failures += 1
            print(f"⚠️  {title} 查询失败: {error}", file=sys.stderr)
            continue
        printed = True

    if args.raw:
        print(json.dumps(result, indent=2, ensure_ascii=False))

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
