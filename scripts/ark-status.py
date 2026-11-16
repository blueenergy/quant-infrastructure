#!/usr/bin/env python3
"""查看 ark-proxy key 池状态（本地 key-rotating 代理，127.0.0.1:8787）。

用法:
    ./scripts/ark-status.py          # 表格输出，cooldown_until 显示为 11-27 23:59
    ./scripts/ark-status.py --raw    # 原始 JSON（cooldown_until 仍是 unix 时间戳）

依赖: 本机 ~/.config/ark-proxy/config.json（local_token）+ ark-proxy.service
      （~/.config/systemd/user/ark-proxy.service）在跑。脚本只读，不改池子状态。

退出码: 0 正常 / 1 代理不可达或鉴权失败 / 2 config 读不到
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

CONFIG_PATH = pathlib.Path.home() / ".config/ark-proxy" / "config.json"


def display_width(text: str) -> int:
    """按终端显示宽度计算（CJK 全角字符占 2 列）。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def pad(text: str, width: int) -> str:
    return text + " " * max(0, width - display_width(text))


def fmt_until(ts: int, now: dt.datetime) -> str:
    """unix 时间戳 -> 11-27 23:59；跨年时带上年份。"""
    if not ts:
        return "-"
    when = dt.datetime.fromtimestamp(ts)
    fmt = "%Y-%m-%d %H:%M" if when.year != now.year else "%m-%d %H:%M"
    return when.strftime(fmt)


def fmt_left(seconds: int) -> str:
    if seconds <= 0:
        return "已到期"
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days}d{hours:02d}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def load_token() -> str:
    try:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.exit(f"找不到配置文件: {CONFIG_PATH} (退出码 2)")
    except json.JSONDecodeError as exc:
        sys.exit(f"配置文件不是合法 JSON: {exc} (退出码 2)")
    token = str(config.get("local_token") or "").strip()
    if not token:
        sys.exit(f"配置里没有 local_token: {CONFIG_PATH} (退出码 2)")
    return token


def fetch_status(token: str) -> dict:
    request = urllib.request.Request(
        "http://127.0.0.1:8787/status",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            sys.exit("401 鉴权失败：local_token 与代理不一致 (退出码 1)")
        sys.exit(f"HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')[:200]} (退出码 1)")
    except urllib.error.URLError as exc:
        sys.exit(f"连不上 ark-proxy (127.0.0.1:8787): {exc.reason} (退出码 1)")
    except TimeoutError:
        sys.exit("请求 /status 超时 (退出码 1)")


def print_table(data: dict) -> None:
    now_dt = dt.datetime.now()
    keys = data.get("keys", [])
    index_to_name = {i: k.get("name", "?") for i, k in enumerate(keys)}

    current_parts = [
        f"{client}={index_to_name.get(index, index)}"
        for client, index in (data.get("current_by_client") or {}).items()
    ]
    print(f"ark-proxy  127.0.0.1:8787  now: {now_dt:%Y-%m-%d %H:%M:%S}")
    print(f"sticky: {'  '.join(current_parts) if current_parts else '-'}")
    print()

    headers = ["KEY", "STATE", "KIND", "解冻时间", "剩余"]
    rows = []
    for key in keys:
        state = key.get("state", "?")
        rows.append(
            [
                key.get("name", "?"),
                state,
                key.get("kind") or "-",
                fmt_until(key.get("cooldown_until", 0), now_dt) if state != "ok" else "-",
                fmt_left(key.get("cooldown_left", 0)) if state != "ok" else "-",
            ]
        )

    widths = [
        max(display_width(row[i]) for row in [headers, *rows])
        for i in range(len(headers))
    ]
    print("  ".join(pad(cell, widths[i]) for i, cell in enumerate(headers)).rstrip())
    print("  ".join("-" * width for width in widths))
    for row in rows:
        line = "  ".join(pad(cell, widths[i]) for i, cell in enumerate(row)).rstrip()
        print(line)

    usable = [k.get("name") for k in keys if k.get("state") == "ok"]
    print()
    if usable:
        print(f"可用 key: {len(usable)}/{len(keys)}  ({', '.join(usable)})")
    else:
        print(f"⚠️  没有可用 key：{len(keys)} 个都在冷却，代理会直接返回 503")


def main() -> None:
    parser = argparse.ArgumentParser(description="查看 ark-proxy key 池状态")
    parser.add_argument("--raw", action="store_true", help="输出原始 JSON（cooldown_until 为 unix 时间戳）")
    args = parser.parse_args()

    data = fetch_status(load_token())
    if args.raw:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print_table(data)


if __name__ == "__main__":
    main()
