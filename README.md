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
5. 更新面板
6. 检查环境
0. 退出
```

“安装配置”通过 SSH 安装 VPS，再添加 SublinkPro 和本地配置；进入这一项后，若有未完成流程，会询问继续上次还是重新开始。“添加配置”可选择 SSH、订阅地址或单条节点链接。“查看配置”区分机场订阅和独立节点，进入详情后可管理中转、删除资源，独立节点还可编辑名称、链接及本地配置。

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

机场名称与节点名称分别自定义。首次交互安装/添加会在连接 SSH 或获取订阅之前分别要求填写，每项输入立即保存，不会默认采用 VPS 主机名；安装时显式配置的 `OKP_NODE_NAME` 可作为节点名称默认值。已保存的名称和已受管配置会复用，命令行 `--airport-name` / `--node-name` 优先；续跑不会用旧 VPS 名称覆盖本次指定的名称。无交互终端且首次未指定名称时，仍使用来源节点名称。更新已有来源使用 `add`，不再提供旧 `sync` 命令。

订阅地址支持 HTTP/HTTPS；只添加机场时，由 SublinkPro 解析它支持的订阅格式。启用本地节点时，本机支持明文 URI 列表或 Base64 订阅中的 **VLESS TCP + REALITY + Vision**。多个可用节点时交互选择一条生成本地出站，非交互可用 `--subscription-node 1` 指定序号；恢复时使用连接指纹识别，避免订阅顺序变化选错节点。机场仍保留整个订阅。自签名证书可在向导中选择，或传入 `--insecure-subscription`；重定向地址需填写最终 URL。交互输入地址可避免将订阅令牌写进 Shell 命令历史。

`ENABLE_LOCAL_NODE` 统一控制 sing-box 和 SublinkPro 本地节点。命令行 `--local-node` / `--no-local-node` 优先于菜单和 `.env`；`--local-port` 隐含启用本地节点，与 `--no-local-node` 互斥。启用但缺少 sing-box 配置会停止。关闭时保留已有本地资源，删除请使用“删除配置”。`install --no-sync` 只安装 VPS。

本地节点名为 `[SM]{节点名称} - 本地`，连接 `127.0.0.1:本地端口`。新建时从 `7896` 起选择未被 SublinkPro 本地 SS、sing-box 入站或系统 TCP/UDP 监听占用的端口，TUI 显示默认值，回车即可接受；也可手动输入 `1–65535` 的端口。非交互时省略 `--local-port` 也会自动选择，已有节点默认保留原端口；编辑端口时可回车保留或输入新值。选定值写入恢复记录，继续流程不会重新分配。这里是 **Surge 所在设备的本地 Shadowsocks 端口**，不在 VPS 上新增监听。sing-box 入站和出站使用 `okp-{管理ID}-in`、`okp-{管理ID}-out`，名称或协议改变不影响 tag 和中转引用。

安装/SSH 添加向导支持主机密码（默认）、私钥、SSH 配置/agent。未写用户名的主机地址或 SSH 别名默认使用 `root`；显式 `user@host` 保留指定用户名。SSH 端口留空沿用配置；`--port 2222` 可覆盖。主机别名也受支持。**`--password` 后面不填写密码**，首次在终端隐藏输入并保存到本机私有凭据文件，后续同一用户名、主机和端口自动复用。OpenSSH 通过 askpass 读取保存的密码，密码不进入进程参数、环境变量或日志；主机指纹仍由用户确认。认证拒绝会清除旧密码，网络失败保留凭据。私钥可用 `--identity ~/.ssh/my_key`，与密码开关互斥；不复制私钥内容。不指定认证参数的直接子命令沿用 SSH 配置/agent。

安装上传当前本机源码（含未提交修改），不要求先 push GitHub。白名单阻止上传 `.env`、Git 历史和 SublinkPro 凭据。AliDNS 等安装默认值经 SSH 输入流送入 root-only 临时文件；VPS 安装器仍保留最终确认页。AliDNS 凭据保存在 VPS 的受保护配置中供续期使用。完成或中断时清理临时文件；断网时可能需要按提示手动清理。

### 单条节点链接

“添加配置 → 单条节点链接”不连接 SSH，也不创建机场。填写链接和节点名称后，选择是否启用本地节点、端口及中转。链接备注可作为名称候选，交互时仍需确认；独立节点不询问机场名称。远端显示名为 `[SM]{节点名称}`，本地显示名为 `[SM]{节点名称} - 本地`。

```bash
okp add --node-link 'socks5://user:password@proxy.example:1080#MyNode' --no-local-node
okp add 'vless://UUID@proxy.example:443?security=tls#MyNode' --local-port 7901
okp add --node-file /absolute/path/private-node.txt --node-name "家宽" --local-port 7902
```

`okp` 是本机配置的 shell alias；也可将示例中的 `okp` 替换为 `python3 deploy.py`。`--node-file` 要求当前用户拥有的 `0600` 普通文件。交互粘贴或私有文件可避免把链接中的凭据写入 Shell 命令历史。

支持 VLESS、Shadowsocks 和 SOCKS5 链接，添加前调用 SublinkPro 的链接解析接口核验。生成本地 sing-box 出站时，VLESS 支持 TCP/raw、WebSocket、gRPC，以及普通 TLS 或 TCP REALITY（可选 Vision）；Shadowsocks 支持标准分享链接和 sing-box 支持的加密方式，暂不转换 plugin 等扩展；SOCKS5 支持有认证或无认证链接及 IPv6。未知或不支持的本地参数会明确报错，不会忽略；可关闭本地节点，或指定另一条可转换的本地出站链接。

添加时可设置“是否为家宽”，新增默认否；选择是后，远端和配套本地 SS 都增加 `家宽` 标签。独立节点的编辑菜单中选择“设置是否为家宽”，机场详情中也提供此项，远程中转组合则在“中转设置”中修改。编辑默认读取当前标签，选择否只移除 `家宽`，保留 `稳定` 和其他标签。机场设置作用于该配置下已导入的全部远端节点；添加家宽订阅时会等待节点拉取，失败可从原流程继续。单独修改标签保留节点 ID、名称和连接参数，不重载 sing-box / Xray。新增远程中转组合默认不继承 A/B 的家宽标签；新启用的本地 SS 跟随所属远端节点的家宽设置。

非交互调用可用 `--residential` / `--no-residential` 设置，例如 `python3 deploy.py edit 某节点 --residential`；省略时保留已有节点的家宽标签。

默认本地出站跟随远端链接；家宽这样的“远端 VLESS、本地 SOCKS”可独立指定：

```bash
okp add --node-file /absolute/path/remote-node.txt --node-name "家宽" \
  --local-link 'socks5://user:password@proxy.example:26193' --local-port 7902 --via 美国
okp edit 家宽 --node-link 'vless://UUID@new.example:443?security=tls'
okp edit 家宽 --same-local
```

更换远端链接会保留独立本地出站。`--same-local` 才会切回跟随远端；`--local-link` 用于修改独立出站。现有已接管的 SOCKS 家宽会保留原出站参数和中转关系。

在“查看配置 → 配置详情 → 编辑配置”中，或用 `okp edit <管理ID或节点名称>`，可按部分修改名称、节点来源、本地节点、独立出站、SSH 连接和 3x-ui 管理。常用命令：

```bash
okp edit 家宽 --node-name "美国住宅"
okp edit 美国住宅 --local-port 7903
okp edit 美国住宅 --no-local-node
okp edit 美国住宅 --via 美国
```

`edit --no-local-node` 会在交互确认后删除配套本地 SS、sing-box 入站/出站/路由，保留远端节点；`add --no-local-node` 仍表示跳过本地修改。被其他本地出站引用时不能关闭。节点作为中转被引用时，改名会同步更新其受管节点的前置代理名称；未受管引用会阻止改名，避免留下断开的引用。sing-box 入站和出站统一使用 `okp-{管理ID}-in`、`okp-{管理ID}-out`，不含显示名称或协议；改名、更换协议均不修改 tag，单独改名不重载 sing-box。

每个独立节点使用随机、稳定的管理 ID；改名或通过 `edit` 更换地址、密码都保持原配置和资源 ID。连接指纹忽略备注与查询参数顺序，用于重复添加识别；不同连接请通过 `edit` 指定原配置，而不是通过 `add` 猜测关联。未受管的同连接节点需要显式 `--adopt-node <节点ID>`，或在向导中确认接管；属于机场的节点不能直接改成独立节点。

清单中独立节点的 `airport_id` 为 `null`、`airport_name` 为空，通过 `remote_node_id` 定位。新增记录为 `kind=node`，原有接管记录仍为 `kind=adopted`。`local_source=remote/custom` 表示本地出站来源，`remote_fingerprints` 只保存连接摘要。受管清单使用版本 3，安装 / 添加 / 节点编辑恢复记录使用版本 2；旧格式需一次性迁移，运行代码不补齐旧字段、不接受旧 tag 或旧格式恢复记录。

### 按部分配置

配置的管理 ID 和名称保持稳定，节点来源、本地节点、SSH 和 3x-ui 管理均可按需补全。“添加配置”选择“稍后补全”，或使用 `python3 deploy.py add --partial --node-name 名称`，只保存基本信息。第三方订阅只需节点来源；没有远端来源时，也可用独立出站启用本地 SS，之后补充来源会保留原端口及独立出站。

详情显示各部分的未设置、已配置、待继续或异常状态；整体 `active` 仅表示当前资源事务已完成。功能执行时会核对实际依赖和连接状态。远程中转落地只需可转换的节点来源；入口需要节点来源、SSH 和 3x-ui 管理。缺项时可选择“补全所需配置并继续”，补全后返回已保存的中转流程，无需重填其他选项。

“编辑配置”提供 SSH 和 3x-ui 管理设置，也可用 `python3 deploy.py edit 管理ID --part ssh` / `--part server` / `--part source`。各部分输入单独保存到 `.deploy-state/part-部分-管理ID.json`，可以继续或修改设置；SSH 成功后独立保存，API 失败不会丢失 SSH 配置，也不阻止修改无关部分。

手动安装的 3x-ui 可补全管理配置：在终端隐藏输入管理员 API Token，通过 SSH 访问服务器本机面板，核对版本、原客户端 UUID、REALITY 参数及入站 ID/tag，再保存独立管理组件。HTTPS 使用输入地址的主机名验证证书并连接服务器 loopback；HTTP 仅允许 loopback。组件位于 `/usr/local/lib/one-key-proxy-relay/`，受保护状态和快照位于 `/etc/one-key-proxy-relay/`。保留原入站、客户端、端口、路由和服务设置，不写入安装器的状态目录，也不自动升级 3x-ui。

变更前验证链接、冲突和候选 sing-box 配置，再写入私有 `node-change-*.json` 事务记录；部分成功后可用 `okp --resume`，或进入该节点继续变更。链接校验或端口冲突在写入资源前失败时，TUI 提供“重新开始”，可以重新填写；重新添加时仅清理尚未使用的登记记录，保留已有配置。事务开始写入后只能继续原操作，不能用“重新开始”或 `--fresh` 替换它，也不能删除或另行改中转。本地 SS 名称有中转引用时也会阻止改名。外部修改会使恢复停止。成功后清除活动事务，修改已有资源的 `node-backup-*.json` 和 sing-box 备份保留供核验。这些备份含敏感参数，均为 `0600` 且被 Git 忽略。恢复文件可能暂存节点链接，`managed.json` 不保存完整链接或密码。

### 更新与未完成流程

SSH 来源按 VPS 安装标识定位；直接订阅来源按 SublinkPro 实例和完整 URL 生成稳定管理 ID。重复添加同一来源会更新同一机场，修改名称不会产生新机场。通过添加导入不同订阅地址会视为新来源；在已有配置的节点来源设置中修改地址，则保留原管理 ID 和机场 ID。机场备注中的独立行 `[okp:管理ID]`、本地分享链接片段 `okp-local:管理ID` 用于验证所有权，显示名称不附带管理 ID。已有配置保留机场设置、名称、本地凭据和标签，仅应用来源变化或显式覆盖。没有管理标识的手工资源不会自动接管。

安装和添加的每个输入完成后立即写入 `.deploy-state/pending.json`；节点编辑按管理 ID 保存到 `edit-管理ID.json`，不会覆盖或被其他配置的安装 / 添加记录阻塞。中断、登录失败或任一步骤失败都会保留；进入安装/添加或对应节点的编辑入口后可继续，也可运行：

```bash
python3 deploy.py --resume
python3 deploy.py --resume --local-port 7901
python3 deploy.py edit 某节点 --resume
python3 deploy.py install root@another-vps --fresh
```

同一来源与配置文件的命令重试自动复用记录，显式参数优先。私钥内容和 SublinkPro API Key 不写入恢复记录；3x-ui 管理 Token 在补全期间保存在私有部分草稿中，成功后转入本地面板凭据文件，服务器也保留受保护的维护凭据；**直接输入的订阅 URL 和节点链接可能含凭据，会保存在私有恢复文件中**。目录权限 `0700`、文件 `0600`，原子写入并共用进程锁；整个目录被 Git 忽略且不会上传到 VPS。每个项目保留一个安装 / 添加流程及每个节点各自的编辑记录，只有本次启用的步骤全部成功才清除，检查和退出不清除。`--resume` 优先恢复安装 / 添加；没有此记录且只有一个节点编辑时会自动恢复，多条编辑需指定节点。`edit --fresh` 只替换该节点的输入，不能替换已经开始写资源的事务。

本地 SSH 密码位于 `.deploy-state/ssh-auth-{目标哈希}.json`，3x-ui 地址及 Token 位于 `.deploy-state/panel-api-{管理ID}.json`；均为当前用户拥有的 `0600` 明文文件，目录为 `0700`，不使用加密或系统钥匙串。SublinkPro 凭据仍在 `0600` 的 `.env`，代理凭据也可能存在 sing-box 配置和受保护的恢复备份中。删除受管配置会清理其面板凭据，SSH 凭据按目标共享保留。

**查看配置 → 选择入口或远程中转 → 诊断面板**通过 API 读取面板/Xray 版本、REALITY 客户端版本限制及原账号和连接参数的匹配状态，不修改面板或代理配置。已有入口尚无本地 Token 时，先经已绑定的 SSH 连接取回；首次仍需输入之前未保存的 SSH 密码。也可运行 `python3 deploy.py inspect-panel 配置名称`。诊断结果保存在 `.deploy-state/panel-report-{管理ID}.json`，不包含 Token、UUID 或密钥。

已确认 VPS 安装完成后，恢复只回读 VPS 并重试添加，不重复安装；安装 ID 改变会停止。集成失败不会回滚 VPS。SublinkPro 机场和本地节点经 API 回读验证，订阅拉取/检测仍为后台异步任务，命令成功不表示这些后台任务已完成。新增资源不会改变已有订阅的固定节点选择。

### 本地配置与中转

候选 sing-box 配置必须通过实际 `sing-box check`，然后保存 `0600` 备份、原子替换并重启 LaunchAgent。重启会短暂中断本地代理连接，失败尝试回滚；外部修改、端口冲突或共享引用会阻止不安全的覆盖/删除。备份位于配置目录的 `.one-key-proxy-backup-*.json`，包含敏感配置。`check` 验证 `.env`、OpenSSH、SublinkPro API 认证及已启用的 sing-box 配置，不更改业务配置或重启服务。

**查看配置 → 选择配置 → 中转设置 → 本地中转** 可修改该配置是否需要本地中转以及使用哪个节点，详情显示当前关系。安装和添加向导也支持本地中转选择。命令行快捷方式：

```bash
python3 deploy.py relay 美国-家宽 --via 美国
python3 deploy.py relay 某节点 --direct
python3 deploy.py add root@your-vps --via 美国
```

设置同时更新 sing-box 出站的 `detour` 与 SublinkPro 远端节点的 `DialerProxyName`，保留原协议、服务器、端口和密码。支持链式中转，拒绝自引用和循环；仍被依赖的中转节点不能删除。本地 SS 继续连接 loopback。机场订阅下载代理与数据通道中转独立。失败保留 `relaying` 状态，可再次进入同一配置的中转设置继续。

### 远程中转

**查看配置 → 选择落地 B → 中转设置 → 远程中转**，选择本脚本管理的入口 VPS A，确认名称及是否启用本地 SS。客户端流量为 `客户端 → A 的 3x-ui → B → 网站`；A 共用原 REALITY 入站和端口，每组组合使用独立 UUID 与专属路由。原 A、B 节点保留，不修改 A 的全局默认出口。支持 VLESS TCP/WS/gRPC 的兼容 TLS/REALITY 配置、无插件的 Shadowsocks AEAD/2022 和 SOCKS5，不能把另一组远程中转作为落地，也不支持明文 VLESS。

入口需要 **3x-ui 3.8.0+（3.x）**、管理员 API 权限和唯一匹配的 VLESS REALITY Vision 节点。节点来源、SSH 与 3x-ui 管理缺项时可在 TUI 补全后继续。本项目安装的入口复用现有运行文件和管理 Token；手动安装的入口使用独立管理组件，隐藏输入 API Token 并核对原客户端及入站身份。检测到版本过低时会询问是否立即更新，成功后继续原流程，已输入的名称、端口和 API Token 会复用。SSH 密码保存在本机私有凭据文件，私钥内容不复制。

选择入口后就保存创建草稿，名称、家宽选项、本地 SS 端口及 SSH 设置每项立即保存。输入或 SSH 失败后，重新进入原落地节点的“中转设置 → 远程中转”，选择“继续上次”；写入远端资源前还可“修改 SSH 设置”或“重新开始”。确认创建后只允许继续原操作，复用同一管理 ID 和事务；不重复询问已确认的选项。SSH 导出会恢复重启后缺失的运行时锁目录，并分别提示认证、项目文件、安装状态和锁占用问题；本机接管节点不代表入口服务器已由本项目安装。

默认 TUI 名称为 `B(A中转)`，例如 `美国-家宽(美国中转)`。SublinkPro 节点为 `[SM]美国-家宽(美国中转)`，可选本地 SS 为 `[SM]美国-家宽(美国中转) - 本地`。本地 SS 只连接 A，不再在本机串联 A、B。默认组合名称会在 A/B 改名或更换落地时自动重算，并同步远端、本地 SS 显示名和受管中转引用。可在组合详情的“中转设置 → 修改名称”中手动命名；手动名称在后续改名、同步和更换落地时保留。名称联动使用同一份可恢复事务，冲突或未受管引用会阻止改名；管理 ID、账号、连接参数和 sing-box tag 保持稳定，单独改名无需连接入口或重载 sing-box / Xray。

```bash
python3 deploy.py remote-relay 美国-家宽 --entry 美国 --no-local-node
python3 deploy.py remote-sync '美国-家宽(美国中转)'
python3 deploy.py edit '美国-家宽(美国中转)' --node-name '美国住宅'
python3 deploy.py remote-relay 美国住宅 --exit-node 另一落地
python3 deploy.py remove 美国住宅
```

组合详情提供中转设置、删除以及“同步 / 继续远程中转变更”。通过脚本更换 B 的远端链接或同步订阅会更新关联组合；独立节点改名、修改家宽标签或本地 SS / 本地出站不触发入口同步，入口离线也可完成这些修改。订阅节点无法按连接指纹识别时需重新选择；没有后台自动同步远程链路。未完成的组合变更会保留原参数，新参数需在原操作完成后提交。B 失联时连接失败，不自动回退 A 直出。配置优先由 3x-ui 热应用，必要时可能短暂重启 A 的 Xray。原有 API 和阻断规则保留优先级；B 承担最终目标的连接及域名解析策略。

创建时先验证专属阻断路由，再新增禁用账号，写入并回读中转路由、检查实际路由匹配及落地连通后才启用。服务器事务保存在 `/etc/one-key-proxy/remote-relays/`，本机创建草稿为 `.deploy-state/remote-create-*.json`，发布事务为 `.deploy-state/remote-relay-*.json`；均为私有目录中的 `0600` 文件，可能包含敏感代理参数。失败后可从原落地的远程中转菜单继续，已登记的组合也可从组合详情继续；未发布本地节点的失败创建可直接删除取消。删除需连接 A 清理专属账号、出站及路由，A 离线时保留删除进度。原 A、B 被引用时不能删除；服务器重配置或卸载前需先清理关联远程中转。

### 更新面板

主菜单 **5. 更新面板**（或 `python3 deploy.py update-panels`）分别显示已登记面板的 3x-ui、Xray 当前版本和目标版本。面板选择同 major 最新稳定版，Xray 自动选择兼容范围内最新的官方数字版本。默认勾选全部可更新面板，包括面板已是最新版、只需调整 Xray 的情况；不兼容的新内核会降至兼容版本。输入一个或多个编号切换 `[x]`，输入 `u` 并确认后依次更新；同一服务器的多个配置合并显示、只更新一次。未设置 SSH、检测失败或无法查询兼容内核时不能勾选；可用 `d 编号` 补全 SSH，再重新检测。不需要先完成节点来源或 3x-ui API 管理。

最低支持版本集中定义在 `lib/panel_version.py` 的 `MIN_PANEL_VERSION`，目前为 `3.8.0`。面板没有更新上限，仅排除预发布、开发版、降级和自动跨 major。Xray 独立使用 `MAX_XRAY_VERSION = '26.7.28'`：sing-box REALITY 暂不兼容 Xray 26.9.8+ 的 ML-KEM 要求，代码注释记录了 [上游问题 #4520](https://github.com/SagerNet/sing-box/issues/4520)，修复并完成连通验证后才可将内核上限设为 `None`。Xray 的旧数字版本也被标记为预发布，因此内核按实际数字 tag 选择，仍排除 alpha / beta / RC 和草稿。2.x 面板可以更新至最新 2.x，但远程中转仍需要 3.x；major 变更需自行处理。API 缺少版本字段时读取服务器二进制版本；版本未知不会被误报为版本过低。

远程中转创建、修改和同步会检查面板及 Xray 版本，遇到面板过旧或内核不兼容时，可确认更新后继续原流程。编辑 / 补全手动安装面板的 3x-ui 管理目前只因面板版本不支持而提示更新，尚未单独检查 Xray 兼容范围；需要时可从主菜单“更新面板”调整内核。仅修改名称、家宽标签和本地节点不检查服务器版本。

自动更新支持标准 Linux systemd、`/usr/local/x-ui` 和 `/etc/x-ui/x-ui.db` 的 SQLite 安装，包括手动安装的面板。面板和内核的官方资产均在下载、SHA-256 及二进制版本校验后才替换；替换前还用选定内核检查现有运行配置。原服务配置、访问路径、数据库和现有节点保留，面板附带的内核被选定兼容版本替代；新安装同样应用内核策略。只调整 Xray 时不执行数据库迁移。更新期间代理会短暂中断。原程序、内核、数据库备份和恢复事务存放于服务器 `/etc/one-key-proxy-panel`，面板、内核启动或健康检查失败会一起恢复，未完成的备份不会用于恢复。SSH 中断后可从更新面板恢复，或在原流程继续时按提示恢复。Docker、OpenRC、外部数据库和自定义安装路径的现有面板需使用原安装工具更新。

### 删除配置

`.deploy-state/managed.json` 持久保存受管资源，不随成功后的恢复记录一起删除。它包含管理 ID、资源 ID、tag、指纹、路径和状态，不包含代理密码、VLESS URI、订阅令牌或 API Key。原有已接管配置仍使用这一清单。

```bash
python3 deploy.py list
python3 deploy.py list --interactive
python3 deploy.py remove <管理ID或配置名称>
```

“删除配置”或配置详情中的删除操作会预览资源并要求确认，清理 sing-box 入站/出站/路由、SublinkPro 机场及导入节点、配套本地 SS 节点，以及已接管的手工远端节点。普通配置**不需要连接过期 VPS**；远程中转需要连接入口清理专属资源，均不会卸载服务器。外部引用会阻止删除；中断保留 `deleting` 状态，再次删除同一配置继续清理，全部成功后才移除记录。

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

`update-3xui` 同样选择当前 major 最新稳定面板及兼容范围内最新的 Xray，使用经过 SHA-256 校验的官方发布包，保留面板根路径及服务配置。更新前备份程序、内核和数据库，并写入恢复事务；启动或项目健康检查失败时恢复原版本与项目状态。中断后，下次维护操作优先恢复未完成的更新，保护备份保留供诊断或恢复。

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
