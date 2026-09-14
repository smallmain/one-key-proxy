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
- 支持本机 `.env` 配置、SSH 部署，以及参考已有配置自动添加 SublinkPro 机场和 Surge 本地 Shadowsocks 节点。

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

## 从本机管理配置

在自己的电脑运行 `python3 deploy.py`，复用 Git 忽略的 `.env`。需要 Python 3.9+ 和 OpenSSH；SSH 安装要求 VPS 可用 root 登录，且已安装 `sh`、`tar`。自动维护本地 sing-box 当前支持 macOS LaunchAgent。

无参数运行进入中文管理菜单，操作完成后返回菜单：

```text
1. 安装配置
2. 添加配置
3. 删除配置
4. 查看配置
5. 检查环境
0. 退出
```

“安装配置”通过 SSH 安装 VPS，再添加 SublinkPro 和本地配置；进入这一项后，若有未完成流程，会询问继续上次还是重新开始。“添加配置”可选择 SSH 读取已安装 VPS，或者直接输入订阅地址，无需安装服务器。“查看配置”可进入每条配置的详情，查看资源、端口、状态和中转关系，并修改该配置的中转设置或删除它。

### 本机配置

首次配置（已有 `.env` 时不要覆盖）：

```bash
cp .env.example .env
chmod 600 .env
```

| 字段 | 用途 |
| --- | --- |
| `SUBLINKPRO_URL` | SublinkPro 的 HTTPS 地址 |
| `SUBLINKPRO_API_KEY` | SublinkPro API Key，仅在本机使用 |
| `ENABLE_LOCAL_NODE` | `true` 同时配置 sing-box 和 SublinkPro 本地节点；`false` 只添加机场，默认 `true` |
| `SUBLINKPRO_GROUP` | 可选机场分组覆盖，内置默认 `SM` |
| `SINGBOX_CONFIG` | 启用本地节点时必填，本机 sing-box JSON 配置路径 |
| `SINGBOX_BINARY` | sing-box 可执行文件，默认从 PATH 查找 `sing-box` |
| `SINGBOX_SERVICE_LABEL` | 启用本地节点时必填，macOS LaunchAgent 标签 |
| `OKP_ALI_ACCESS_KEY_ID` | 普通 VPS 使用的 AliDNS RAM AccessKey ID |
| `OKP_ALI_ACCESS_KEY_SECRET` | AliDNS RAM AccessKey Secret |
| `OKP_ACME_EMAIL` | ACME 邮箱，可留空 |

机场和本地节点模板内置于 `deploy_templates.py`，无需已有机场 ID、节点 ID 或 sing-box 模板 tag。机场默认采用 `SM` 分组、每天更新、`[SM]` 前缀、节点名称预处理及唯一化，并开启流量获取和更新后检测（检测配置 ID 为 `1`）。新本地 SS 节点使用 `aes-128-gcm`、独立随机密码和“稳定”标签，sing-box 与 SublinkPro 使用相同密码；更新已有节点保留其密码、分组和标签。

`.env` 一行一个 `KEY=value`，支持整行注释和整值单/双引号；不会执行 Shell 或展开变量，不支持行尾注释和多行值。未知字段、重复字段、链接或非 `0600` 文件会被拒绝。`.env` 和 `.env.*` 被 Git 忽略，只有无敏感值的 `.env.example` 入库。`0600` 限制访问权限，内容仍是明文。更多安装默认值见示例文件，缺失的必需项仍会交互询问。

### 安装与添加

```bash
python3 deploy.py check
python3 deploy.py install root@your-vps --password
python3 deploy.py install root@your-vps --mode public --domain hk1.example.com \
  --airport-name "我的香港 VPS" --node-name "香港备用" --local-port 7900
python3 deploy.py add root@your-vps --password
python3 deploy.py add --interactive
python3 deploy.py add 'https://your-vps.example/sub/your-token' --no-local-node
python3 deploy.py add --subscription-url 'https://your-vps.example/sub/your-token' \
  --airport-name "我的机场" --node-name "香港备用" --local-port 7900
```

机场名称与节点名称分别自定义。首次未指定时会询问；SSH 来源默认使用 VPS 节点名称，订阅来源默认使用选中的节点名。无需重复填写已完成的名称与端口。旧命令 `sync` 保留为 `add` 的兼容别名。

订阅地址支持 HTTP/HTTPS；只添加机场时，由 SublinkPro 解析它支持的订阅格式。启用本地节点时，本机支持明文 URI 列表或 Base64 订阅中的 **VLESS TCP + REALITY + Vision**。多个可用节点时交互选择一条生成本地出站，非交互可用 `--subscription-node 1` 指定序号；恢复时使用连接指纹识别，避免订阅顺序变化选错节点。机场仍保留整个订阅。自签名证书可在向导中选择，或传入 `--insecure-subscription`；重定向地址需填写最终 URL。交互输入地址可避免将订阅令牌写进 Shell 命令历史。

`ENABLE_LOCAL_NODE` 统一控制 sing-box 和 SublinkPro 本地节点。命令行 `--local-node` / `--no-local-node` 优先于菜单和 `.env`；`--local-port` 隐含启用本地节点，与 `--no-local-node` 互斥。启用但缺少 sing-box 配置会停止。关闭时保留已有本地资源，删除请使用“删除配置”。`install --no-sync` 只安装 VPS。

本地节点名为 `[SM]{节点名称} - 本地`，连接 `127.0.0.1:本地端口`。端口首次必须填写，范围为 `1–65535`；后续可复用或修改。这里是 **Surge 所在设备的本地 Shadowsocks 端口**，不在 VPS 上新增监听。sing-box 创建 `ss-{节点名称}-in`、`vless-{节点名称}-out` 和对应路由；已接管的 SOCKS 出站使用 `socks-{节点名称}-out`。tag 创建后保持稳定，名称改变不破坏中转引用。

安装/SSH 添加向导支持主机密码（默认）、私钥、SSH 配置/agent。SSH 端口留空沿用配置；`--port 2222` 可覆盖。主机别名也受支持。**`--password` 后面不填写密码**，OpenSSH 在终端中确认主机指纹并无回显输入密码，然后复用共享连接上传和读取状态。密码不进入 Python、进程参数、环境变量或临时文件。私钥可用 `--identity ~/.ssh/my_key`，与密码开关互斥。不指定认证参数的直接子命令沿用 SSH 配置/agent。

安装上传当前本机源码（含未提交修改），不要求先 push GitHub。白名单阻止上传 `.env`、Git 历史和 SublinkPro 凭据。AliDNS 等安装默认值经 SSH 输入流送入 root-only 临时文件；VPS 安装器仍保留最终确认页。AliDNS 凭据保存在 VPS 的受保护配置中供续期使用。完成或中断时清理临时文件；断网时可能需要按提示手动清理。

### 更新与未完成流程

SSH 来源按 VPS 安装标识定位；直接订阅来源按 SublinkPro 实例和完整 URL 生成稳定管理 ID。重复添加同一来源会更新同一机场，修改名称不会产生新机场。直接订阅地址变化会视为新来源，可删除旧配置后重新添加。机场备注中的独立行 `[okp:管理ID]`、本地分享链接片段 `okp-local:管理ID` 用于验证所有权，显示名称不附带管理 ID。已有配置保留机场设置、名称、本地凭据和标签，仅应用来源变化或显式覆盖。没有管理标识的手工资源不会自动接管。

每个输入完成后立即写入 `.deploy-state/pending.json`。中断、登录失败或任一添加步骤失败都会保留；进入安装/添加后可继续或重新开始，也可运行：

```bash
python3 deploy.py --resume
python3 deploy.py --resume --local-port 7901
python3 deploy.py install root@another-vps --fresh
```

同一来源与配置文件的命令重试自动复用记录，显式参数优先。主机密码、私钥内容、API Key 和原始 VLESS URI 不写入恢复记录；**直接输入的订阅 URL 可能含令牌，会保存在此私有恢复文件中**。目录权限 `0700`、文件 `0600`，原子写入并加进程锁；整个目录被 Git 忽略且不会上传到 VPS。每个项目保留一个未完成流程，只有本次启用的步骤全部成功才删除记录，检查和退出不清除。

已确认 VPS 安装完成后，恢复只回读 VPS 并重试添加，不重复安装；安装 ID 改变会停止。集成失败不会回滚 VPS。SublinkPro 机场和本地节点经 API 回读验证，订阅拉取/检测仍为后台异步任务，命令成功不表示这些后台任务已完成。新增资源不会改变已有订阅的固定节点选择。

### 本地配置与中转

候选 sing-box 配置必须通过实际 `sing-box check`，然后保存 `0600` 备份、原子替换并重启 LaunchAgent。重启会短暂中断本地代理连接，失败尝试回滚；外部修改、端口冲突或共享引用会阻止不安全的覆盖/删除。备份位于配置目录的 `.one-key-proxy-backup-*.json`，包含敏感配置。`check` 验证 `.env`、OpenSSH、SublinkPro API 认证及已启用的 sing-box 配置，不更改业务配置或重启服务。

**查看配置 → 选择配置 → 中转设置** 可修改该配置是否需要中转以及使用哪个节点，详情显示当前关系。安装和添加向导也支持选择。命令行快捷方式：

```bash
python3 deploy.py relay 美国-家宽 --via 美国
python3 deploy.py relay 某节点 --direct
python3 deploy.py add root@your-vps --via 美国
```

设置同时更新 sing-box 出站的 `detour` 与 SublinkPro 远端节点的 `DialerProxyName`，保留原协议、服务器、端口和密码。支持链式中转，拒绝自引用和循环；仍被依赖的中转节点不能删除。本地 SS 继续连接 loopback。机场订阅下载代理与数据通道中转独立。失败保留 `relaying` 状态，可再次进入同一配置的中转设置继续。

### 删除配置

`.deploy-state/managed.json` 持久保存受管资源，不随成功后的恢复记录一起删除。它包含管理 ID、资源 ID、tag、指纹、路径和状态，不包含代理密码、VLESS URI、订阅令牌或 API Key。原有已接管配置仍使用这一清单。

```bash
python3 deploy.py list
python3 deploy.py list --interactive
python3 deploy.py remove <管理ID或配置名称>
```

“删除配置”或配置详情中的删除操作会预览资源并要求确认，清理 sing-box 入站/出站/路由、SublinkPro 机场及导入节点、配套本地 SS 节点，以及已接管的手工远端节点。**不需要连接过期 VPS**，不会卸载服务器。外部引用会阻止删除；中断保留 `deleting` 状态，再次删除同一配置继续清理，全部成功后才移除记录。

### 明确接管现有配置

`adopt` 接受当前用户拥有的 `0600` JSON 清单，可明确关联现有 sing-box 入站/出站、SublinkPro 机场或手工远端节点、本地节点及中转关系，并批量重命名引用。清单包含 `groups` 数组（每项含 `name`、`inbound`、`outbound`、`airport_id`、`remote_node_id`、`local_node_id`、`relay`），以及明确允许移除的 `remove_inbounds`、`remove_outbounds` 和 `default_outbound`。`relay` 使用同一清单中的分组名称；手工远端节点的 `airport_id` 为 `null`。

```bash
python3 deploy.py adopt .deploy-state/adopt-existing.json
```

接管会先核验本地 SS 凭据、远端配置和现有中转关系，再保存备份，给 SublinkPro 资源添加管理标识，最后一次性重写 sing-box 并重载。现有 SublinkPro 显示名与连接参数保留。接管记录标记为 `adopted`，管理 ID 在本机生成，并非声称这些 VPS 由安装器创建；此类资源可直接使用 `relay` 和 `remove` 管理，无需 SSH。

中断后重复同一份清单会核对并继续；外部修改会使接管停止。`.deploy-state/adoption-*.json` 是 `0600` 的敏感接管备份，包含原始代理配置，已被 Git 忽略。成功后保留用于审计/恢复。删除手工接管的部署会同时清理其手工远端节点；内置模板不受资源删除影响。

## 安装前准备

### NAT VPS

先在服务商后台创建以下三组 **TCP** 端口映射，并记录每组外部端口和内部端口：

| 服务 | 示例映射 | 用途 |
| --- | --- | --- |
| 面板 HTTPS | `56664:2053` | 外部 `56664` 转发到 VPS `2053` |
| VLESS 节点 | `56665:443` | 外部 `56665` 转发到 VPS `443` |
| 订阅 HTTPS | `56666:2096` | 外部 `56666` 转发到 VPS `2096` |

端口提示会显示默认内部端口：面板 `2053`、VLESS `443`、订阅 `2096`。可只输入外部端口，例如面板输入 `56664` 等同于 `56664:2053`；也可填写完整映射覆盖内部端口。首次必须填写服务商分配的外部端口。修改已有映射时，回车保留当前映射，只填外部端口会保留当前内部端口。`.env` 中的 `OKP_PANEL_MAP`、`OKP_NODE_MAP`、`OKP_SUB_MAP` 同样支持只填外部端口。

安装时只需确认或输入：

- 公网 IPv4；
- 上述三组外部端口，内部端口可使用默认值或显式指定。

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

面板用户名和密码默认随机生成，也可以在最终确认页修改。标准 `bootstrap.sh` 会以干净环境启动主安装器，不透传任意 `OKP_*` 配置变量；本机 SSH 入口通过显式的 `--defaults-file` 提供白名单默认值。所有参数都必须经过交互确认，项目不提供静默 `--yes` 安装。

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

依赖 Bash、Python 3.9+、ShellCheck，以及测试所需的常见 Unix 工具。

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
