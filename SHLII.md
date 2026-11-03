# Shlii 接入

## 接入方式

Shlii 的普通账号接入使用官网前端调用的网页协议。官网另有分销 API 文档，采用 `/api/reseller/open` 和请求签名；没有证据表明它覆盖普通账号的实例与登机牌，因此本项目不使用分销 API。

以下接口和字段来自官方前端的调用及消费位置。前端代码能够确定客户端如何构造请求，不能单独证明所有账号都有相同权限或服务端始终返回相同字段。自动测试使用模拟响应；实际验证范围应与测试结果分别说明。

## 登录和会话

| 请求 | 用途与字段 |
| --- | --- |
| `POST /api/auth/login` | `username`、`password`、`device`；按需附加 `totpCode`、`deviceVerificationCode`、`deviceVerificationMethod`。成功读取 `token`、`user.id`。 |
| `POST /api/auth/refresh` | 携带 Cookie 和原 `device`，读取新的 `token` 与账号信息。 |
| `GET /api/auth/me` | 登录响应缺少账号信息时读取 `user`，核对产品所属账号。 |
| `POST /api/auth/login-device-challenge` | `challengeToken`、`deviceVerificationMethod`、`device`；邮件或 Telegram 发送验证码后重新提交登录。 |

访问令牌通过 `Authorization: Bearer` 发送。持久登录同时保留 Cookie 的域、路径、到期信息和安全属性，以及同一设备标识；不能只保存访问令牌。业务请求收到认证拒绝时，恢复登录后最多重发一次；`SESSION_INVALIDATED` 不重发。

`TWO_FA_REQUIRED` 和 `INVALID_2FA_CODE` 进入验证码输入。新设备验证根据 `verificationMethods` 提供邮件、Telegram 或动态验证码选项。需要 Turnstile 等网页验证时，启动普通 Chrome 独立窗口，由用户完成验证和登录，并在终端按回车后再连接浏览器读取会话。账号核对成功后才替换原账号。密码和完整节点链接不进入进程参数或日志。

Cloudflare 不支持使用自动化浏览器完成生产环境验证，见 [支持的浏览器](https://developers.cloudflare.com/cloudflare-challenges/reference/supported-browsers/)。本项目不在验证期间连接浏览器或自动操作验证码；读取会话后继续使用网页协议请求。

## 实例

| 请求 | 用途与字段 |
| --- | --- |
| `GET /api/instances?page=1&pageSize=100` | `instances`、`totalPages`；拉取全部分页。 |
| `GET /api/instances/:id` | `instance` 中的 `network_mode`、`nat_public_ip`、`ipv4`、`ssh_port`、`ssh_public_port`、`port_mappings`、端口范围和数量限制。 |
| `GET /api/instances/:id/password` | `rootPassword`；没有可用密码时通过原 SSH 流程补填。 |
| `POST /api/instances/:id/ports` | 确认后创建 TCP 映射：`protocol`、`privatePort`、`publicPort`、`remark`。 |

SSH 先从 TCP 映射查找内部 SSH 端口，再使用其外部端口；缺少映射时回退到 `ssh_public_port`。映射同时接受官网使用的两种字段形式：`private_port/public_port`、`privatePort/publicPort`。

安装缺少映射时，仅从已分配端口范围中选择未使用的外部端口，并核对数量限制。每次创建前重新读取已有映射，创建后再次核验；超时不直接认定失败，先确认服务端是否已经创建。失败或中断保留已创建映射，继续时不重复创建。

只有 IPv6 入口的实例不能进入当前安装流程。读取产品信息不表示服务器已经安装本项目；“添加配置”仍检查远端安装标识和完成状态。

## 登机牌

| 请求 | 用途与字段 |
| --- | --- |
| `GET /api/airport/overview` | `tickets`，对应官网“我的行程”中的产品。 |
| `GET /api/airport/tickets/:id` | `ticket` 及已有 `forwardingAllocations`。 |
| `GET /api/airport/tickets/:id/subscription` | `subscription.usable` 和格式可用性。 |
| `POST /api/airport/tickets/:id/subscription/reveal` | 空对象请求；读取 `subscription.paths[ipv4或ipv6].v2raynPath`。 |
| `GET v2raynPath` | Base64 或明文的多行节点链接；仅向 Shlii 本站发送请求。 |
| `GET /api/airport/tickets/:id/multi-exit` | 已存在且就绪的 `variants`。 |
| `GET /api/airport/tickets/:id/multi-exit/:variantId/boarding-pass?family=ipv4或ipv6` | 多出口的 `link`。 |
| `GET /api/airport/tickets/:id/forwarding/:allocationId/boarding-pass?family=ipv4或ipv6` | 已有代理转发入口的 `link`。 |

读取链接不会创建转发或出口。每次导入选择一个入口，区分普通入口、多出口、转发和地址类型。普通入口按名称及协议识别，多出口和转发使用服务端标识；链接顺序变化不会改选另一条。无法稳定区分的同名入口明确停止，原入口消失时不自动替换。

订阅路径和链接包含凭据，不显示完整内容。产品关联仅保存账号、产品及入口标识；完整链接沿用原流程的私有恢复记录管理。TUIC 等现有流程不支持的链接展示原因，不进行有损转换。

## 官方依据

- [主前端：请求接口和会话处理](https://shlii.io/assets/mIr3OTnf.js)
- [登录页面：验证码、新设备和 Turnstile 分支](https://shlii.io/assets/DCKYJ4oi.js)
- [实例列表与分页](https://shlii.io/assets/OBUQf4FB.js)
- [实例详情、密码及端口映射](https://shlii.io/assets/CE_Cew6h.js)
- [登机牌、订阅及派生入口](https://shlii.io/assets/DRpmpyAt.js)
- [分销 API 文档](https://shlii.io/reseller/api-docs)

## 验证范围

已用真实账号验证普通 Chrome 手动登录、登录状态保存和恢复、实例列表、NAT 实例详情、SSH 密码读取、登机牌列表及链接读取。已观察到套餐协议标识使用 `shadowsocks_aes_256_gcm`、`vless_tcp_reality_vision` 等名称，列表识别这些标识后仍以实际链接解析结果核验兼容性。

真实验证没有创建端口映射、安装或重配服务器，也没有修改 SublinkPro。端口创建后的回读、失败恢复、重复导入和保留已有本地配置等行为通过自动测试验证。
