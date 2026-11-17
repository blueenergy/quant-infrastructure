#!/usr/bin/env python3
"""一次性查看本机 LLM 额度：Ark key 池（ccp）+ MiniMax Token Plan（ccm）。

用法:
    llm-status              # 两块都查
    llm-status --ark        # 只看 Ark key 池
    llm-status --minimax    # 只看 MiniMax Token Plan
    llm-status --raw        # 原始 JSON

退出码: 0 全部正常 / 1 至少一块查询失败（配置缺失也算失败）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys
import unicodedata
import urllib.error
import urllib.request

ARK_CONFIG = pathlib.Path.home() / ".config/ark-proxy" / "config.json"
ARK_STATUS_URL = "http://127.0.0.1:8787/status"
MINIMAX_PROFILE = pathlib.Path.home() / ".claude/profiles" / "minimax.json"
MINIMAX_URL = "https://api.minimax.io/v1/token_plan/remains"


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
        inactive = item.get("current_interval_status") not in (1, None)
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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="查看本机 LLM 额度：Ark key 池 + MiniMax Token Plan"
    )
    parser.add_argument("--ark", action="store_true", help="只看 Ark key 池")
    parser.add_argument("--minimax", action="store_true", help="只看 MiniMax Token Plan")
    parser.add_argument("--raw", action="store_true", help="输出原始 JSON")
    args = parser.parse_args()

    only_ark = args.ark and not args.minimax
    only_minimax = args.minimax and not args.ark

    result: dict[str, object] = {}
    failures = 0

    if not only_minimax:
        data, error = fetch_ark()
        result["ark"] = data if error is None else {"error": error}
        if error is None:
            if not args.raw:
                render_ark(data)
        else:
            failures += 1
            print(f"== Ark key 池 ==\n⚠️  查询失败: {error}\n", file=sys.stderr)

    if not only_ark:
        data, error = fetch_minimax()
        result["minimax"] = data if error is None else {"error": error}
        if error is None:
            if not args.raw:
                if not only_minimax:
                    print()
                render_minimax(data)
        else:
            failures += 1
            print(f"== MiniMax Token Plan ==\n⚠️  查询失败: {error}\n", file=sys.stderr)

    if args.raw:
        print(json.dumps(result, indent=2, ensure_ascii=False))

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
