# REALITY 安全与版本核查

核查日期：2026-11-02。本记录区分 Cloudflare 回落滥用、客户端握手兼容性，以及版本本身的安全更新。

## 默认目标与已有部署

新安装默认使用 `www.tencentcloud.com:443`，客户端 SNI 为 `www.tencentcloud.com`，可通过 `OKP_REALITY_TARGET` 覆盖。核查时本机解析到 `www.tencentcloud.com.eo.dnse3.com`，HTTPS 返回 `TencentEdgeOne`；这是一次观察，不代表其他地区或未来的解析结果，也没有证明该共享目标不能转发其他站点。

已有安装推荐从本机 `python3 deploy.py` 选择 **5. 更新配置**：一次确认后同步运行脚本、更新面板/兼容内核、将旧默认 Cloudflare 目标迁移到腾讯云，并刷新 SublinkPro、已启用的本机节点及关联远程中转。中转组合、专属账号和路由原地保留；入口 SNI 和落地出站参数会自动同步，不需要先删除组合。自定义目标保留；失败后再次进入该项继续。其他设备仍需要刷新订阅。

仅希望在 VPS 上手动迁移时，先更新本项目运行文件，再执行：

```bash
one-key-proxy reconfigure reality
```

维护菜单第 10 项提供同一操作。输入新的 `域名:端口`，预检可信 TLS、确认差异并成功创建保护备份后，才更新受管入站的目标和 SNI。保留端口、UUID、客户端、密钥及 Short ID；回读配置并检查订阅交付后更新结果。失败时保留保护备份供原机恢复。该手动命令不能同步本机中转配置，有中转依赖时请使用本机第 5 项自动迁移。

随后刷新所有客户端订阅，或手工更新 SNI；通过本机 `deploy.py add` 重新同步该来源，更新本地 sing-box 出站。单独修改仓库默认值、升级面板或重新启动都不会迁移旧目标。

## 官方问题与升级效果

| 问题 | 官方依据 | 判断 |
| --- | --- | --- |
| 未认证连接回落到共享 CDN，被借用转发流量 | [Xray PR #4553](https://github.com/XTLS/Xray-core/pull/4553)、[REALITY 文档](https://xtls.github.io/config/transports/reality.html#realityobject) | PR 在 2025-06-08 合入可选回落限速；升级不会自动关闭回落。限速只降低单连接速率，不是访问控制。此次采用更换目标，不默认添加有识别特征的限速配置。 |
| sing-box 无法连接 Xray 26.9.8+ REALITY | [sing-box issue #4520](https://github.com/SagerNet/sing-box/issues/4520)、[v1.14.4 客户端代码](https://github.com/SagerNet/sing-box/blob/v1.14.4/common/tls/reality_client.go#L149-L164) | 核查时 issue 仍开放；官方稳定客户端仍主动移除 X25519MLKEM768，修改 minClientVer 不能修复。issue 中的修复分支不等于正式发布。 |
| 面板对空 minClientVer 的文案与新内核行为不一致 | [3x-ui issue #6568](https://github.com/MHSanaei/3x-ui/issues/6568) | issue 关闭涉及提示文案修正，不能据此认定 sing-box 的 ML-KEM 兼容性已修复；本项目继续显式设置 `1.0.0`。 |
| MPTCP 安全更新 | [Xray v26.10.31 发布说明](https://github.com/XTLS/Xray-core/releases/tag/v26.10.31) | 官方最新版本默认关闭 MPTCP，并建议更新 Linux 内核；这是独立问题。保留旧 Xray 的兼容策略不能替代该安全修复。 |

3x-ui 当前最新稳定版为 [v3.11.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0)，自带 Xray v26.10.21；面板最新并不代表内核最新。本项目面板策略没有版本上限，仍选同 major 最新稳定版，内核单独选择并校验。该版本官方安装脚本通过了本项目的下载形状校验；本次没有执行远程面板安装或升级。

## 实测矩阵

使用核对过 GitHub Release SHA-256 的官方 macOS arm64 二进制，在临时目录启动隔离实例，监听地址均为 `127.0.0.1`。服务端配置为 VLESS/TCP/REALITY/Vision，`minClientVer=1.0.0`，目标 `www.tencentcloud.com:443`，客户端均使用 `chrome` 指纹。通过临时 SOCKS5 入口访问 `https://www.tencentcloud.com/`，验证完整代理请求。未使用已有代理凭据，未修改现有服务。

| 客户端 | Xray 服务端 | 结果 |
| --- | --- | --- |
| Xray v26.10.31 | v26.10.31 | HTTP 200 |
| sing-box v1.14.4 | v26.10.31 | `reality verification failed`，HTTP 000 |
| Xray v26.10.31 | v26.7.28 | HTTP 200 |
| sing-box v1.14.4 | v26.7.28 | HTTP 200 |

因此目前保留 `MAX_XRAY_VERSION = '26.7.28'`，避免升级后切断现有 sing-box 客户端。该上限是兼容折中，不是安全版本推荐；要使用最新 Xray，需先迁移或修复依赖 sing-box 的客户端，并对所有实际客户端和中转链路完成连通验证。仅最新 Xray 客户端通过本矩阵，不代表所有客户端已经兼容。

更换目标后仍应从外部核验实际公网入口，尤其是 NAT 映射端口。DMIT 检测页前端按 443 处理结果，不能用它的一次阴性结果证明其他端口没有回落转发风险。
