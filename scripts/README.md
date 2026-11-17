# scripts/

运维与 CI 辅助脚本。除特别说明外均可直接执行，不依赖仓库内其他目录。

| 脚本 | 用途 | 运行环境 |
|---|---|---|
| [`llm-status.py`](./llm-status.py) | 一条命令查 Ark key 池 + MiniMax Token Plan 额度 | WSL 开发机 |
| [`bump-versions-env.sh`](./bump-versions-env.sh) | 由 app 仓库 CI 调用，bump `apps/versions.env` + 写 CHANGELOG | GitHub Actions |
| [`wait-for-acr-tag.sh`](./wait-for-acr-tag.sh) | 阻塞等待镜像 tag 在阿里云 ACR 可读，避免空部署 | GitHub Actions |
| [`notify_ci_dingtalk.py`](./notify_ci_dingtalk.py) | CI 失败时发钉钉 markdown 告警 | GitHub Actions |
| [`test_notify_ci_dingtalk.py`](./test_notify_ci_dingtalk.py) | 上面那个的 stdlib unittest | GitHub Actions |

## llm-status.py

一条命令查两个 Claude Code 后端的剩余额度：

- **Ark key 池**（`ccp`）：读本机 `ark-proxy` 的 `/status`，把 `cooldown_until`
  的 unix 时间戳转成 `11-27 23:59`，并给出剩余时间
- **MiniMax Token Plan**（`ccm`）：调 `https://api.minimax.io/v1/token_plan/remains`，
  显示本期窗口（5 小时）和本周池的**剩余百分比**

```bash
./scripts/llm-status.py            # 两块都查
./scripts/llm-status.py --ark      # 只看 Ark
./scripts/llm-status.py --minimax  # 只看 MiniMax
./scripts/llm-status.py --raw      # 原始 JSON
```

```
== Ark key 池 (ark-proxy 127.0.0.1:8787) ==  now: 2026-11-17 12:06:27
sticky: openai=ark7  anthropic=ark7

KEY   STATE     KIND   解冻时间     剩余
----  --------  -----  -----------  ------
ark7  cooldown  quota  11-17 14:26  2h20m
...
⚠️  没有可用 key：7 个都在冷却，ccp 会直接返回 503

== MiniMax Token Plan (ccm) ==  api.minimax.io/v1/token_plan/remains

MODEL           本期剩余  本期结束     本期倒计时  本周剩余  本周结束     本周倒计时
--------------  --------  -----------  ----------  --------  -----------  ----------
general         45%       11-17 13:00  53m         83%       11-23 08:00  5d19h
video (未启用)  100%      11-18 08:00  19h53m      100%      11-23 08:00  5d19h
```

- `--raw`：输出 `{"ark": {...}, "minimax": {...}}`，时间戳保持原始单位（Ark 为秒，MiniMax 为毫秒）
- 两个数据源互不影响：一个挂了另一个照常显示，失败信息走 stderr
- `STATE=cooldown` 但 `剩余=已到期`：代理的标记还没刷新，下次被选中时会自动转 `ok`
- MiniMax 百分比字段是**剩余**不是已用（接口字段名叫 `usage_count`，历史坑）
- 退出码：`0` 全部正常 / `1` 至少一块查询失败（配置文件缺失也走 `1`）

前置条件（都是本机个人环境，不进仓库）：

- `~/.config/ark-proxy/config.json`，其中 `local_token` 用于 Ark 代理鉴权；
  `systemctl --user status ark-proxy` 为 running
- `~/.claude/profiles/minimax.json` 里的 `ANTHROPIC_AUTH_TOKEN`（`sk-cp-…`）；
  注意 `sk-api-…` 的按量计费 key 调不通这个接口

已知边界：Ark 脚本读的是代理**内存里的**状态，重启服务会清空 cooldown（但不代表
上游额度恢复，下一次请求仍会 429 并重新标记）；`kind` 只记录**最后一次**失败的
类型——例如周额度到点解冻后，月额度可能仍然超限，要等真正发请求才会暴露。
