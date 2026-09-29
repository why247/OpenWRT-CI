# HomeProxy 简洁版改造：Redirect + TPROXY 透明代理

基于上游 `VIKINGYFY/packages`（`main` 分支，`luci-app-homeproxy` PKG_VERSION `20260922`）
的独立 patch 集。**其他功能、界面一律不动**，只做以下改造：

## 改了什么

| # | patch | 内容 |
|---|-------|------|
| 1 | `homeproxy-scripts-generate_client.uc.patch` | 删除 TUN 客户端（`tun-in`），改为 TCP `redirect-in` + UDP `tproxy-in`；控制规则的 inbound 匹配同步改为这两个；大陆模式删除 `geoip-cn`（rule-set、DNS 响应判断、路由规则），只保留 `geosite-cn` 域名兜底；所有出站（含 WireGuard/Tailscale endpoint）加 `routing_mark` 防回环 |
| 2 | `homeproxy-scripts-firewall_pre.uc.patch` | 生成 `/var/run/homeproxy/fw4_client.nft`：nftables set（`hp_cn4`/`hp_cn6` 来自 `cn_ip.list`、`hp_wan_direct*` 来自界面手动直连、`hp_local*` 保留地址）+ 4 条自有 base chain（TCP redirect prerouting/output、UDP tproxy prerouting/output 打 mark）。规则顺序：自身 mark → 保留地址 → 手动直连 → **CN IP 直接 return（内核层绕过，不进 sing-box）** → 其余进代理 |
| 3 | `init.d-homeproxy.patch` | 启动时配置 TPROXY 策略路由（fwmark → table 100 → local route，v4/v6），停止时彻底清理；`clear_firewall` 同步清理 `fw4_client.nft` |
| 4 | `uci-defaults-luci-homeproxy.patch` | 新增 firewall include `homeproxy_client`（`table-post`，指向 `fw4_client.nft`） |
| 5 | `homeproxy-scripts-update_resources.sh.patch` | 数据源换 MetaCubeX：`cn_ip.list`（`meta` 分支 geoip 文本，供 nftables）+ `geosite_cn.srs`（`sing` 分支预编译二进制，供 sing-box，与 Nikki 的 mrs 同一份数据）；无版本号上游改用 sha256 比对；下载→校验→原子替换，失败保留旧文件 |
| 6 | `Makefile.patch` | 依赖：去掉 `+kmod-tun`，加 `+kmod-nft-tproxy`、`+ip-full` |

另外 `patches/files/` 下有一份预置的 `cn_ip.list`（2026-09-29 快照，9611 条）及其 sha256
`cn_ip.ver`，`apply-patches.sh` 会原样拷进源码树，保证首次启动就有内核层绕过数据，
之后由更新逻辑按 hash 刷新。`geosite_cn.srs` 沿用包内预置文件，首次更新即被 MetaCubeX
版本替换；`geoip_cn.srs` 不再被任何代码引用（保留文件不动）。

## 用法（接进 GitHub Actions 构建）

```sh
# 在拉取 luci-app-homeproxy 源码后、编译前执行：
sh /path/to/homeproxy-rt/apply-patches.sh /path/to/luci-app-homeproxy
```

- 脚本先对全部 patch 做 `patch --dry-run --fuzz=0` 预检，**任何一个失配就直接退出非零**，
  Actions 构建失败，不会静默跳过。`--fuzz=0` 表示上下文差一行也不行，防止上游小改动
  被 patch 悄悄“消化”掉。
- 预检通过后才真正应用（同样 `--fuzz=0`）。
- `patches/files/` 下的数据文件原样拷入源码树。

`PRIVATE.sh` 接入示例（路径按你的构建实际调整）：

```sh
# HomeProxy redirect/tproxy 改造
HP_SRC="$GITHUB_WORKSPACE/packages/main/luci-app-homeproxy"   # 按实际路径改
sh "$GITHUB_WORKSPACE/Scripts/homeproxy-rt/apply-patches.sh" "$HP_SRC"
```

## 数据更新节奏

- `cn_ip.list`：MetaCubeX 每天 06:30（CST）构建；路由器每 6 小时检查一次（沿用原有 cron），
  有变化则下载→校验→原子替换；随后 cron 触发 `homeproxy reload`，nftables set 跟着刷新，
  **不用手动重启**。
- `geosite_cn.srs`：同上；sing-box 本地规则集需重启生效，cron 的 reload 会处理。

## 上游更新后怎么办（patch 维护）

1. 上游 `VIKINGYFY/packages` 更新后，重新跑 `apply-patches.sh`。
2. 如果某 patch 失配导致构建失败：把新的上游文件 diff 出来，手动把对应 hunk 挪到新位置，
   更新 `patches/` 下的 patch 文件（保持文件名和顺序），重新跑。
3. 不要改文件名排序（按文件名字典序应用）。

## 验证状态

- [x] shell 脚本 `sh -n` 语法检查通过
- [x] 生成的 nftables 规则用 `nft -c` 做过语法校验（redirect/tproxy/mark 语句形式；
      另用 9611 条真实 CN CIDR 生成完整 set 并通过解析）
- [x] 代表性 sing-box 配置（含 redirect/tproxy inbound、`routing_mark`、真实 MetaCubeX
      `cn.srs`、1.14 版 DNS 结构）用 `sing-box check` 校验通过
- [x] `apply-patches.sh` 端到端验证：干净树应用后与修改树一致；上下文被改动时
      `--fuzz=0` 预检失败并退出非零
- [x] `update_resources.sh` 的 `validate_cidr_list` 用 9612 条真实数据验证全通过；
      `sing-box rule-set match` 验证 `cn.srs` 可命中 `www.baidu.com`
- [ ] **未做实机验证**：需在 AP8220 上实测 TCP/UDP 分流、CN 绕过、WireGuard 节点、
      Tailscale、重启/停止清理、纯服务端模式（客户端禁用时无拦截）

## 已知行为变化

- TUN 客户端彻底移除（含界面里的 TUN 参数不再生效，界面本身不动）。
- 大陆模式下，无域名信息的纯 CN IP 流量：nftables 层已直接放行；若经由 `mixed-in` 等
  直达 sing-box 的入口（无 nftables 路径），将按“其他流量默认代理”处理——这是按需求
  去掉 `geoip-cn` 后的预期行为。
- IPv6 相关 nft 规则与策略路由只在 `ipv6_support=1` 时生成。
