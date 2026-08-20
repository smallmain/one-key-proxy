# one-key-proxy

[English](README_EN.md) | [详细设计](DESIGN.md)

在目标 VPS 上直接运行的交互式 3x-ui 安装与维护工具。它会安装 3x-ui 的最新稳定版，并创建一个 VLESS + TCP + REALITY + XTLS-Vision 入站。面板路径固定为 `/`，REALITY `minClientVer` 固定为 `1.0.0`；这里约束的是客户端内置的 Xray-core 版本，不是客户端应用自身的版本号。

项目支持 NAT VPS 和拥有独立公网地址的普通 VPS。安装前会汇总自动生成的参数并允许逐项修改；最终确认后才会创建或变更代理、面板、DNS、证书和防火墙资源。为保证引导程序能够运行，`bootstrap.sh` 可能在确认页之前安装 Bash、CA 证书、curl、tar 和 gzip 等最低下载依赖。

> [!WARNING]
> NAT 模式使用裸 IPv4 和自签名 HTTPS 证书。订阅客户端必须支持“跳过证书验证/允许不安全证书”，否则只能手动导入 VLESS URI。跳过验证后，HTTPS 无法阻止中间人伪装面板或篡改订阅；请通过独立可信渠道核对安装结果中的证书 SHA-256 指纹。此风险不改变 REALITY 数据通道本身的安全机制。

## 功能

- 运行时获取 3x-ui 最新稳定 Release，不使用开发版，也不静默降级。
- 要求官方 Release 为目标架构提供 SHA-256 摘要；首次安装和主动更新会把 tag 固定到 commit，校验架构资产并把有限的 `main` helper 固定到同一 commit。下载形状检查用于发现已适配调用方式的漂移，不是 Shell 沙箱；固定 commit 的官方安装器本身仍属于以 root 执行的信任根。
- 自动生成面板凭据、UUID、Sub ID、X25519 密钥和 Short ID。
- 固定部署 VLESS + TCP + REALITY + XTLS-Vision。
- NAT 模式支持三组非 1:1 的 `外部端口:内部端口` TCP 映射。
- 普通 VPS 模式通过 AliDNS 创建 A/AAAA，并使用 DNS-01 签发 Let's Encrypt 证书。
- 仅修改已经启用的 UFW/firewalld；其他防火墙只打印建议。
- 默认尝试安装 Fail2ban，失败只告警，不阻断核心部署。
- 分阶段执行并支持失败后续跑。
- 输出 Base64、Xray JSON、Clash/Mihomo 订阅和 VLESS URI；安装终端支持时额外显示二维码。
- 提供状态、诊断、备份恢复、更新、重配置、凭据轮换和卸载菜单。

## 支持范围

| 项目 | 支持范围 |
| --- | --- |
| CPU | `amd64`、`arm64` |
| Debian 系 | Debian、Ubuntu 及可正确识别的主流衍生版 |
| RHEL 系 | RHEL、Rocky Linux、AlmaLinux、CentOS Stream、Fedora |
| Alpine 系 | Alpine Linux |
| Arch 系 | Arch Linux |
| SUSE 系 | openSUSE Leap、openSUSE Tumbleweed |
| init | systemd、OpenRC |
| 网络 | IPv4 必需；普通 VPS 可选全局可路由 IPv6 |

未知发行版、非 `amd64/arm64`、不受支持的 init，或无法正常管理服务的容器环境会在预检阶段停止，不做部分安装。

## 一键安装

必须在目标 VPS 上以 `root` 身份执行。不要在自己的电脑上运行这些命令。

使用 curl：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh)
```

使用 wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh)
```

最小化系统还没有 Bash 时，先用 POSIX Shell 启动引导程序；它会安装 Bash 后继续：

```sh
curl -fsSL https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh | sh
```

```sh
wget -qO- https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh | sh
```

引导程序和安装器从 `/dev/tty` 读取交互输入，因此管道中的脚本内容不会被当作用户输入。

上述一行命令直接执行 `main` 分支上的引导脚本，信任边界包括 GitHub、TLS 和仓库维护者；引导脚本只能保证其后下载的所有项目文件来自同一 commit，无法反过来验证自己。正式发布时应同时发布带版本的 `bootstrap.sh` 和 SHA-256，要求更强供应链保证时先下载、核对发布页给出的校验值，再执行固定 tag：

```bash
curl -fL -o bootstrap.sh https://github.com/smallmain/one-key-proxy/releases/download/vX.Y.Z/bootstrap.sh
printf '%s  %s\n' '<发布页中的 SHA-256>' bootstrap.sh | sha256sum -c -
ONE_KEY_PROXY_REF=vX.Y.Z sh bootstrap.sh
```

## 安装前准备

### NAT VPS

先在服务商后台创建以下三组 **TCP** 端口映射，并记录每组外部端口和内部端口：

| 服务 | 示例映射 | 用途 |
| --- | --- | --- |
| 面板 HTTPS | `56664:2053` | 外部 `56664` 转发到 VPS `2053` |
| VLESS 节点 | `56665:443` | 外部 `56665` 转发到 VPS `443` |
| 订阅 HTTPS | `56666:2096` | 外部 `56666` 转发到 VPS `2096` |

安装时只需确认或输入：

- 公网 IPv4；
- 上述三组 `外部端口:内部端口`。

所有服务只需要 TCP，不需要开放 UDP。脚本不会操作 NAT 服务商后台，也不能替你验证所有供应商的端口映射。公网 IP 变化后必须运行维护菜单中的“更新公网地址”，然后重新导入订阅或节点。

最终状态仅提供 HTTPS。不过 3x-ui 官方安装器首次启动服务后，脚本才能立即把面板改为回环监听并配置 TLS；这之间可能存在短暂的初始 HTTP 暴露窗口。若安装器失败，脚本会先尝试把残留面板限制到 `127.0.0.1`，无法确认时停止 x-ui。安装期间仍应在服务商防火墙/安全组中把面板映射限制为你的管理 IP，成功后再按需调整。

### 普通 VPS

准备一个由 AliDNS 管理的完整子域名，例如 `hk1.example.com`，以及 Aliyun RAM 子账号的 AccessKey ID 和 AccessKey Secret。ACME 邮箱可以留空。

默认端口如下，最终确认页可修改：

| 服务 | 默认端口 |
| --- | --- |
| VLESS 节点 | `443/tcp` |
| 面板 HTTPS | `2053/tcp` |
| 订阅 HTTPS | `2096/tcp` |

脚本会创建或核验 A 记录，并在确认启用 IPv6 时创建 AAAA；禁用 IPv6 时只删除本项目拥有的 AAAA，并在仍存在任何 AAAA 时停止，避免域名继续发布旧的 IPv6 地址。它不会覆盖 CNAME、多个不一致记录或无法证明归属的记录。证书通过 AliDNS DNS-01 签发，不要求为 ACME 单独开放 `80/tcp`。

## AliDNS RAM 最小权限

请创建专用 RAM 用户，不要使用阿里云主账号 AccessKey。第一版需要以下最小动作集合来发现域名、核验记录、创建/更新发布记录，以及供 acme.sh 创建和删除 DNS-01 TXT 记录：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:DescribeDomains",
        "alidns:DescribeDomainRecords",
        "alidns:DescribeDomainRecordInfo",
        "alidns:AddDomainRecord",
        "alidns:UpdateDomainRecord",
        "alidns:DeleteDomainRecord"
      ],
      "Resource": "*"
    }
  ]
}
```

若你的 AliDNS RAM 策略支持对域名资源 ARN 施加限制，请进一步限定为需要管理的 DNS Zone。AccessKey 会保存在 VPS 的 root-only 配置目录中，供证书自动续期使用；它不会写入结果文件或普通日志。

## 交互过程

1. 选择 NAT VPS 或普通 VPS。
2. 输入该模式必需的端口、域名或 AliDNS 信息。
3. 工具自动生成其余安全参数并执行安装器预检；REALITY 目标必须能完成 DNS 解析、TCP 连接和受信任的 TLS 握手。
4. 最终确认页显示完整配置；可以按编号修改。
5. 再次确认后才开始创建或变更 3x-ui、DNS、TLS 和防火墙配置。

引导层是例外：缺少下载工具时，它会在进入确认页前通过系统包管理器安装最低依赖；Arch Linux 会因此执行 `pacman -Syu`。最终确认后，RHEL 系安装 Fail2ban 时还可能以尽力而为方式安装 `epel-release`；失败只会记录为降级告警。

面板用户名和密码默认随机生成，也可以在最终确认页修改。标准 `bootstrap.sh` 会以干净环境启动主安装器，不透传任意 `OKP_*` 配置变量；部署参数必须通过交互流程采集和确认，项目不提供静默 `--yes` 安装。

如果系统上已有非本项目管理的 3x-ui，安装器会停止且不会接管。中途失败时，重新运行同一入口会严格校验阶段名称、完成时间和适用的真实后置条件，再从失败处继续。首次调用官方安装器前会写入恢复事务；若中断时只落下二进制，或结果文件已经写入但服务尚未完成，续跑会核对已确认身份、停止并禁用残留服务，再以同一版本和配置重放。只有尚无阶段标记、证书或 3x-ui 资源的初始化中断状态才会被保守清理；无法证明安全时会停止并要求诊断。

## 安装结果

成功后终端和 `/root/one-key-proxy-result.txt` 会显示：

- 3x-ui 版本与服务状态；
- 面板 URL、用户名和密码；
- 外部/内部 TCP 端口清单；
- Base64、Xray JSON、Clash/Mihomo 订阅链接；
- 完整 VLESS URI；
- 维护命令、备份位置和降级告警。

如果已安装可选的 `qrencode`，二维码只显示在当前终端，不写入结果文件。结果文件权限为 `0600`，属于敏感文件。它不包含 Aliyun AccessKey Secret、管理 API Token、REALITY 私钥或 TLS 私钥。

## 维护

安装完成后运行：

```bash
one-key-proxy
```

无参数时进入中文菜单。稳定子命令包括：

```text
info                  查看部署信息
status                快速检查服务、内部 TCP 监听、证书和阶段标记
doctor                深查管理 API/Token、入站、Host、Xray、面板/订阅设置、证书身份和 Fail2ban
backup                创建全量敏感备份
restore               在原服务器恢复备份
update-3xui            备份后手动更新 3x-ui
self-update            手动更新本项目
update-address         手动更新公网地址
reconfigure-ports     重配监听和发布端口
reconfigure-domain    重配普通 VPS 域名
renew-cert            手动检查或续签证书
rotate-panel          轮换面板凭据
rotate-token          轮换管理 API Token
rotate-client         创建新客户端并保留旧客户端
remove-client         确认迁移后删除旧客户端
uninstall             逐项卸载
```

本项目和 3x-ui 都不会在后台自动升级。普通 VPS 会保留证书续期任务，但项目 **不会安装 DDNS**：A/AAAA 只在首次安装，或用户主动更新公网地址、重配域名时变化。

`update-3xui` 会在运行官方更新器前写入恢复事务。针对当前 3x-ui v3.6 更新器可能把固定的面板根路径 `/` 随机化的行为，更新后会先停止 x-ui，通过本地 CLI 离线写回并回读 `/`，再启用自启、启动服务并进行首次本机 3x-ui API 与 Xray 检查。若更新中断，下次维护操作会先重放该恢复；路径回读或健康检查失败时 x-ui 保持停止且禁用自启，事务和更新前备份保留供诊断/恢复。

域名、NAT 公网 IP 或证书发生切换时，维护流程使用可恢复的两阶段 TLS 状态。中断后进入任一维护操作都会先核验证书 SAN 和已保存身份：确认新证书已写入时受控重启并保留事务供原操作续跑，确认仍是旧证书时清理未使用事务，无法判定时停止诊断。只有新身份通过本机 HTTPS/API 与 Xray 健康检查后才清理活动事务并刷新结果文件。

## 备份、恢复与卸载警告

- 全量备份包含 3x-ui 数据库、管理 Token、AliDNS 凭据和证书私钥，权限为 `0600`；泄露备份等同于泄露服务器凭据。
- 备份位于 `/var/backups/one-key-proxy`，默认保留最近 5 份。第一版只保证在创建备份的原服务器上恢复，不承诺跨 VPS 迁移。
- 恢复会停止并重启服务；网络参数与备份不一致时必须重新确认配置。
- 卸载默认选中完整卸载，但每类受管资源都可取消；执行任何卸载前都会强制创建完整备份。
- DNS 记录、防火墙规则和其他外部资源只有通过所有权校验后才会删除。
- 卸载不会删除备份；卸载前备份会保留在上述目录，需要时只能由管理员另行手动清理。

## 安全说明与限制

- 面板路径固定为 `/`，容易被扫描；请保管强密码，并主动检查更新。
- NAT 的自签名证书不受公共 CA 信任；允许不安全证书会暴露中间人风险，必须独立核对安装结果中的 SHA-256 指纹。动态 IP 变化还会同时使证书 SAN、订阅 URL 和节点地址失效。
- 普通 VPS 的证书会自动续期，但没有 DDNS；公网地址变化仍需手动执行 `update-address`。
- REALITY 预检只证明目标当时可完成 DNS、TCP 和受信任的 TLS 连接，不保证目标长期可用或适合作为所有网络环境中的伪装站点。
- 3x-ui 最新稳定版若发生 API 破坏性变更，工具会安全停止并保留已安装面板，不会自动降级。
- 固定到 commit 的 3x-ui 官方安装器仍是 root 信任代码；资产摘要、helper 固定和下载形状检查降低供应链漂移风险，但不能证明任意上游 Shell 不含恶意行为。
- Fail2ban 在部分发行版上可能降级为告警；RHEL 衍生版会尽力安装 EPEL，但不会在卸载时移除共享的 EPEL 仓库或 Fail2ban 软件包。
- 裸 nftables/iptables 不会被自动修改，必须按结果提示自行开放内部 TCP 端口。
- 脱敏运行日志写入 `/var/log/one-key-proxy.log`，权限为 `0600`。

完整行为、状态机和安全边界见 [DESIGN.md](DESIGN.md)。

## 开发

依赖 Bash、ShellCheck，以及测试所需的常见 Unix 工具。

```bash
git clone https://github.com/smallmain/one-key-proxy.git
cd one-key-proxy
```

运行 ShellCheck：

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck
shellcheck one-key-proxy
```

运行测试：

```bash
bash tests/run.sh
```

提交变更前请同时执行两项检查。真实 AliDNS、ACME、systemd/OpenRC、NAT 和防火墙行为仍需要在一次性 VPS/VM 上做集成测试。

## License

[MIT](LICENSE)
