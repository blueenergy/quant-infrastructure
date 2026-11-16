# scripts/

运维与 CI 辅助脚本。除特别说明外均可直接执行，不依赖仓库内其他目录。

| 脚本 | 用途 | 运行环境 |
|---|---|---|
| [`ark-status.py`](./ark-status.py) | 查看本机 `ark-proxy` key 池状态 | WSL 开发机 |
| [`bump-versions-env.sh`](./bump-versions-env.sh) | 由 app 仓库 CI 调用，bump `apps/versions.env` + 写 CHANGELOG | GitHub Actions |
| [`wait-for-acr-tag.sh`](./wait-for-acr-tag.sh) | 阻塞等待镜像 tag 在阿里云 ACR 可读，避免空部署 | GitHub Actions |
| [`notify_ci_dingtalk.py`](./notify_ci_dingtalk.py) | CI 失败时发钉钉 markdown 告警 | GitHub Actions |
| [`test_notify_ci_dingtalk.py`](./test_notify_ci_dingtalk.py) | 上面那个的 stdlib unittest | GitHub Actions |

## ark-status.py

`ark-proxy` 是 WSL 开发机上的本地 key 轮换代理（`127.0.0.1:8787`），
`ccp` / `ccx` 这类命令通过它复用一组 Ark key。上游返回
`AccountQuotaExceeded` 时，代理会把该 key 打进 cooldown，直到响应里给出的
reset 时间；所有 key 都在冷却时直接返回 503。

本脚本把 `/status` 的 `cooldown_until`（unix 时间戳）转成 `11-27 23:59`：

```bash
./scripts/ark-status.py
```

```
ark-proxy  127.0.0.1:8787  now: 2026-11-16 11:54:33
sticky: openai=ark7  anthropic=ark7

KEY   STATE     KIND   解冻时间     剩余
----  --------  -----  -----------  ------
ark7  ok        -      -            -
ark6  cooldown  quota  12-05 23:59  19d12h
...
ark2  cooldown  quota  11-16 14:04  2h09m

可用 key: 1/7  (ark7)
```

- `--raw`：输出原始 JSON，`cooldown_until` 保持 unix 时间戳，便于其他脚本消费
- `STATE=cooldown` 但 `剩余=已到期`：代理的标记还没刷新，下次被选中时会自动转 `ok`
- 退出码：`0` 正常 / `1` 代理未启动或 `local_token` 不匹配 / `2` 配置文件读不到

前置条件（都是本机个人环境，不进仓库）：

- `~/.config/ark-proxy/config.json`，其中 `local_token` 用于鉴权
- `systemctl --user status ark-proxy` 为 running

已知边界：脚本读的是代理**内存里的**状态，重启服务会清空 cooldown（但不代表
上游额度恢复，下一次请求仍会 429 并重新标记）；`kind` 只记录**最后一次**失败的
类型——例如周额度到点解冻后，月额度可能仍然超限，要等真正发请求才会暴露。
