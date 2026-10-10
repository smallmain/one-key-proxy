# one-key-proxy

[中文](README.md) | [Detailed design (Chinese)](DESIGN.md)

An interactive installer and maintenance tool that runs directly on the target VPS. It installs the latest stable 3x-ui release and creates one VLESS + TCP + REALITY + XTLS-Vision inbound. The panel path is fixed to `/`, and REALITY `minClientVer` is fixed to `1.0.0`; this is the minimum version of the Xray-core embedded by a client, not the client application's own version.

Both NAT VPS instances and regular VPS instances with a dedicated public address are supported. Generated values are shown on a final review screen and can be edited before proxy, panel, DNS, certificate, or firewall resources are changed. To make the bootstrap runnable, `bootstrap.sh` may install the minimum Bash, CA certificate, curl, tar, and gzip dependencies before that review.

> [!WARNING]
> NAT mode uses a raw IPv4 address and a self-signed HTTPS certificate. The subscription client must support skipping certificate verification; otherwise, import the VLESS URI manually. Once verification is skipped, HTTPS cannot prevent a man-in-the-middle from impersonating the panel or modifying a subscription. Compare the certificate SHA-256 fingerprint in the installation result through an independent trusted channel. This risk does not alter the REALITY data channel itself.

## Features

- Resolves the latest stable 3x-ui release at install time; no development builds or silent downgrades.
- Requires an official SHA-256 digest for the architecture-specific release asset, resolves the tag to a commit, verifies the asset, and pins a finite set of `main` helpers to that commit. Downloader-shape checks detect drift from the adapted call pattern; they are not a shell sandbox, and the official installer at the pinned commit remains trusted root code.
- Generates panel credentials, UUID, subscription ID, X25519 keys, and Short ID.
- Deploys VLESS + TCP + REALITY + XTLS-Vision with `minClientVer=1.0.0`.
- Supports three non-1:1 `external:internal` TCP mappings in NAT mode.
- Creates AliDNS A/AAAA records and obtains a Let's Encrypt certificate through DNS-01 in regular VPS mode.
- Only modifies UFW or firewalld when already enabled; other firewall setups receive instructions only.
- Attempts to enable Fail2ban by default without making it a hard deployment dependency.
- Uses resumable, verified installation stages.
- Outputs raw Base64, Xray JSON, Clash/Mihomo subscriptions, and a VLESS URI; displays a QR code in a capable installation terminal.
- Provides status, diagnostics, backup/restore, updates, reconfiguration, credential rotation, and removal.
- Supports local `.env` configuration, SSH deployment, and SublinkPro airports plus Surge local Shadowsocks nodes based on existing references.

## Supported platforms

| Item | Supported |
| --- | --- |
| CPU | `amd64`, `arm64` |
| Debian family | Debian, Ubuntu, and correctly detected mainstream derivatives |
| RHEL family | RHEL, Rocky Linux, AlmaLinux, CentOS Stream, Fedora |
| Alpine family | Alpine Linux |
| Arch family | Arch Linux |
| SUSE family | openSUSE Leap, openSUSE Tumbleweed |
| init | systemd, OpenRC |
| Network | IPv4 required; globally routable IPv6 optional in regular VPS mode |

Unknown distributions, unsupported architectures/init systems, and containers without functional service management are rejected during preflight without a partial installation.

## One-line installation

Run this as `root` **on the target VPS**, not on your local computer.

With curl:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh)
```

With wget:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh)
```

If a minimal system does not have Bash yet, start the POSIX bootstrap with `sh`; it installs Bash before continuing:

```sh
curl -fsSL https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh | sh
```

```sh
wget -qO- https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh | sh
```

Prompts are read from `/dev/tty`, so piped script data cannot be consumed as user input.

The one-line commands execute the bootstrap from `main`, so their trust boundary includes GitHub, TLS, and the repository maintainers. The bootstrap ensures that subsequent project files come from one commit, but it cannot authenticate itself retroactively. For a stronger release workflow, publish a versioned `bootstrap.sh` and SHA-256 together, then download and verify that published value before running a fixed tag:

```bash
curl -fL -o bootstrap.sh https://github.com/smallmain/one-key-proxy/releases/download/vX.Y.Z/bootstrap.sh
printf '%s  %s\n' '<SHA-256 from the release page>' bootstrap.sh | sha256sum -c -
ONE_KEY_PROXY_REF=vX.Y.Z sh bootstrap.sh
```

## Manage configurations from your computer

Run `python3 deploy.py` on your computer to reuse a Git-ignored `.env`. Requires Python 3.9+ and OpenSSH; SSH installation needs root access, `sh`, and `tar` on the VPS. Automatic local sing-box integration currently supports macOS LaunchAgents.

The Chinese management menu returns after each operation:

```text
1. 安装配置 (Install)
2. 添加配置 (Add)
3. 删除配置 (Delete)
4. 查看配置 (View)
5. 更新面板 (Update panels)
6. 检查环境 (Check environment)
0. 退出 (Exit)
```

Install sets up a VPS over SSH and adds its resources. An unfinished workflow is offered for resume or restart after entering Install/Add. Add supports SSH, subscription URLs, or a single node link. View distinguishes airports from standalone nodes; standalone details also provide name, link and local-node editing. Relay editing belongs to each configuration.

### Local configuration

Create the private file once, without overwriting an existing one:

```bash
cp .env.example .env
chmod 600 .env
```

| Key | Purpose |
| --- | --- |
| `SUBLINKPRO_URL` | SublinkPro HTTPS address |
| `SUBLINKPRO_API_KEY` | API key, used only on this computer |
| `ENABLE_LOCAL_NODE` | Default `true`: configure both sing-box and SublinkPro local nodes; `false`: airport only |
| `SUBLINKPRO_GROUP` | Optional airport group override; built-in default is `SM` |
| `SINGBOX_CONFIG` | Required with local nodes: user-owned `0600` sing-box JSON file |
| `SINGBOX_BINARY` | Executable path; default `sing-box` on PATH |
| `SINGBOX_SERVICE_LABEL` | Required with local nodes: macOS LaunchAgent label |
| `OKP_ALI_ACCESS_KEY_ID` | AliDNS RAM access key ID for public VPS installations |
| `OKP_ALI_ACCESS_KEY_SECRET` | AliDNS access key secret |
| `OKP_ACME_EMAIL` | Optional ACME email |

Templates live in `deploy_templates.py`; no existing airport IDs, local-node IDs, or sing-box template tags are required. Airport defaults include group `SM`, daily updates, prefix `[SM]`, custom node renaming, uniqueness, usage collection and post-update detection (profile ID `1`). New local nodes use `aes-128-gcm`, an independent random password and the “稳定” tag. sing-box and SublinkPro receive identical local credentials; updates retain existing credentials, groups and tags.

The literal dotenv reader accepts whole-line comments and matching quotes, without shell evaluation or expansion. Unknown/duplicate keys, links, control characters, and files not owned by you with mode `0600` are rejected. `.env` and `.env.*` are ignored; only the empty example is tracked. Permissions restrict access but do not encrypt the file.

### Install and add

```bash
python3 deploy.py check
python3 deploy.py install root@your-vps --password
python3 deploy.py add root@your-vps --password
python3 deploy.py add --interactive
python3 deploy.py add 'https://your-vps.example/sub/your-token' --no-local-node
python3 deploy.py add --subscription-url 'https://your-vps.example/sub/your-token' --airport-name "My airport" --node-name "Hong Kong" --local-port 7900
```

Airport and node names are independently configurable. First interactive imports require both names before SSH or subscription fetching, checkpointing each answer immediately without defaulting to the VPS hostname. An explicit `OKP_NODE_NAME` may provide the installation node-name default. Saved and managed names are reused; explicit flags take precedence, including when a resumed VPS still exports an older name. Noninteractive first imports retain source-name defaults when names are omitted. `--name` aliases `--node-name`. Use `add` to update existing sources; the old `sync` command is no longer accepted.

HTTP/HTTPS subscription URLs are supported. For airport-only imports, SublinkPro handles its supported formats. Creating a local outbound requires a plain URI list or Base64 subscription containing **VLESS TCP + REALITY + Vision**. Choose one compatible node interactively when there are several, or pass `--subscription-node 1`. Resume stores its connection fingerprint so reordering cannot select another node. The airport retains the whole subscription. Self-signed certificates require the wizard option or `--insecure-subscription`; redirects require entering the final URL. Interactive URL input avoids putting access tokens in shell history.

`--local-node` and `--no-local-node` override the wizard and `.env`. `--local-port` implies local nodes and conflicts with `--no-local-node`. Local nodes require sing-box configuration and always configure both systems. Disabling local nodes leaves existing local resources intact; use Delete to remove them. `install --no-sync` installs only the VPS.

Companion nodes are named `[SM]{node name} - 本地` and connect to `127.0.0.1:local-port`. New nodes select an available port starting at `7896`, skipping SublinkPro local SS ports, configured sing-box listeners and system TCP/UDP listeners. The TUI shows the default; press Enter to accept it or enter a port from `1-65535`. Noninteractive imports also select a port when `--local-port` is omitted. Existing nodes retain their port unless overridden; the port edit prompt accepts Enter to keep it. The selected port is checkpointed and reused after failure. This port belongs to the Surge device, not the VPS. sing-box tags use `okp-{managementID}-in` and `okp-{managementID}-out`, staying unchanged after name or protocol changes.

The SSH wizard supports host password (default), private key, or SSH configuration/agent. Bare hosts and SSH aliases default to `root`; explicit `user@host` retains that username. A blank port retains SSH defaults; override with `--port 2222`. Host aliases are supported. **Do not put a password after `--password`**: enter it privately in the terminal once, then reuse the saved credential for the same user, host and port. OpenSSH retrieves it through askpass; passwords do not enter process arguments, environment variables or logs. Host keys still require user confirmation. Rejected authentication clears the saved password; network failures retain it. `--identity ~/.ssh/my_key` selects a private key and conflicts with password mode; private-key contents are not copied. Direct commands without authentication flags retain SSH configuration/agent behavior.

Install uploads local runtime sources, including uncommitted edits, without requiring a GitHub push. An allowlist excludes `.env`, Git history and SublinkPro credentials. AliDNS and installation defaults cross SSH stdin into a root-only temporary file; the VPS installer retains its confirmation page. AliDNS credentials remain in protected VPS configuration for renewal. Temporary files are cleaned up on completion/interruption, with manual cleanup potentially needed after a disconnect.

### Single node links

Choose Add → Single node link. This creates a manual remote node in SublinkPro without SSH or an airport. The wizard collects the link, node name, local-node setting, local port and relay. A link remark can be a name suggestion, confirmed interactively. Names are `[SM]{name}` for the remote node and `[SM]{name} - 本地` for the companion local node.

```bash
okp add --node-link 'socks5://user:password@proxy.example:1080#MyNode' --no-local-node
okp add --node-file /absolute/path/private-node.txt --node-name "Home" --local-port 7901
```

`okp` is a locally configured shell alias; `python3 deploy.py` works without it. `--node-file` requires a user-owned `0600` regular file. Interactive input and private files avoid storing credentials in shell history.

VLESS, Shadowsocks and SOCKS5 are supported and checked against SublinkPro's link parser. Local VLESS conversion supports TCP/raw, WebSocket, gRPC, plain TLS, and TCP REALITY with optional Vision. Shadowsocks supports standard share formats and ciphers accepted by the sing-box binary; plugin extensions are not converted locally. SOCKS5 supports optional credentials and IPv6. Unsupported local parameters fail explicitly; use airport-independent remote storage alone or provide a supported local outbound.

Add asks whether the node is residential, defaulting to No for new configurations. Yes adds the `家宽` tag to the remote node and its companion local SS. Change it in a standalone node's edit menu, an airport's details, or a remote combination's relay settings. Edits default to the current tag; No removes only `家宽`, preserving `稳定` and other tags. Airport changes apply to all currently imported nodes of that configuration. Adding a residential subscription waits for imported nodes, with recoverable failures. Tag-only changes preserve IDs, names and connections without reloading sing-box or Xray. New remote combinations do not inherit A/B's residential tag; newly enabled local SS follows its remote node.

For noninteractive calls, use `--residential` / `--no-residential`, for example `python3 deploy.py edit NodeName --residential`. Omitting the flag preserves existing nodes' residential tags.

The local outbound normally follows the remote link. A separate local link preserves combinations such as a VLESS remote node with a SOCKS residential exit:

```bash
okp add --node-file /absolute/path/remote-node.txt --node-name "Home" \
  --local-link 'socks5://user:password@proxy.example:26193' --local-port 7902 --via US
okp edit Home --node-link 'vless://UUID@new.example:443?security=tls'
okp edit Home --same-local
```

Changing the remote link preserves a custom local outbound. `--local-link` changes that outbound; `--same-local` explicitly returns to following the remote. Existing adopted SOCKS exits retain their connection and relay settings.

Use View → standalone node → Edit, or `okp edit <management-id-or-node-name>`, to change its name, remote link, local port, local-node setting or separate outbound. Examples:

```bash
okp edit Home --node-name "Residential"
okp edit Residential --local-port 7903
okp edit Residential --no-local-node
okp edit Residential --via US
```

`edit --no-local-node` confirms and removes the companion SS node and sing-box listener/outbound/route, preserving the remote node. `add --no-local-node` continues to skip local changes. References from other local outbounds block disabling. Renaming a relay updates its managed dependent nodes' dialer names; unmanaged references block renaming. All managed sing-box inbounds and outbounds use `okp-{managementID}-in` and `okp-{managementID}-out`, without display names or protocols. Tags remain unchanged after renaming or protocol changes; a name-only edit does not reload sing-box.

Standalone nodes receive independent, stable management IDs. Explicit `edit` operations preserve IDs across name, address or password changes. Connection fingerprints ignore remarks and query ordering to recognize repeated imports. Adding a different connection creates a different configuration; use `edit` to replace one. Existing unowned manual nodes require `--adopt-node <node-id>` or confirmation in the wizard; airport-owned nodes cannot be silently converted to standalone nodes.

Standalone records have `airport_id=null`, an empty `airport_name`, and use `remote_node_id`. New records use `kind=node`; adopted records retain `kind=adopted`. `local_source=remote/custom` describes the local outbound, and `remote_fingerprints` stores only digests. Inventory uses version 3; install/add/node-edit checkpoints use version 2. Older data requires a one-time migration; runtime code does not fill missing old fields or accept old tags or recovery formats.

### Optional Configuration Parts

Each configuration retains a stable management ID and name. Its node source, local node, SSH connection and 3x-ui management are optional. Select Add → Fill later, or run `python3 deploy.py add --partial --node-name NAME`, to save basic information. Local SS can use an independent outbound without a remote source; adding a source later preserves its port and independent outbound.

Details show configured, unset, pending or failed parts. `active` describes completion of resource transactions. Features verify their actual dependencies before running: a remote exit needs a convertible source, while the entry also needs SSH and 3x-ui management. Fill missing configuration and continue returns to the original saved relay creation.

Edit configuration provides each part, also available through `edit ID --part ssh`, `--part server` or `--part source`. Private `.deploy-state/part-PART-ID.json` checkpoints preserve inputs independently. SSH configuration survives later API failures, and pending server configuration does not block unrelated node edits.

Existing manually installed 3x-ui can complete management configuration. Enter an admin API token privately in the terminal. The independent component verifies the original client UUID, REALITY settings, inbound ID/tag, panel version and API permissions before writing management files. API calls run on the SSH server's loopback interface; HTTPS verifies certificates using the supplied hostname, while HTTP is restricted to loopback. Components live in `/usr/local/lib/one-key-proxy-relay/` and private state/snapshots in `/etc/one-key-proxy-relay/`. Existing clients, inbounds, ports, routing and service settings are retained. Installer ownership and automatic panel upgrades are not introduced.

Each change validates links, conflicts and any sing-box candidate before writing a private `node-change-*.json` transaction. After partial success, use `okp --resume` or reopen that node to continue. If link validation or a port conflict fails before resources are written, the TUI offers Restart so you can revise the input. Restarting Add removes only an unused registration and preserves existing configurations. Once resource writes start, Restart and `--fresh` cannot replace the transaction; new parameters, deletion and separate relay operations must wait for completion. References to the companion local SS name also block renaming. External edits stop recovery. Active journals are cleared on success; `node-backup-*.json` snapshots of modified resources and sing-box backups remain for inspection. Backups contain sensitive parameters and are user-owned `0600` Git-ignored files. Recovery files may temporarily contain links; the inventory does not store full links or passwords.

### Updates and recovery

SSH imports use the VPS installation ID; URL imports derive a stable management ID from the SublinkPro instance and full URL. Repeating the same source updates the same airport independently of display names. Adding a different subscription URL creates a new source; editing the source part of an existing configuration retains its management and airport IDs. Ownership uses a standalone `[okp:management-id]` airport remark and `okp-local:management-id` local link fragment, separate from display names. Existing settings are preserved unless explicitly overridden. Unmarked manual resources are not automatically adopted.

Install/Add inputs are immediately checkpointed in `.deploy-state/pending.json`. Node edits use `edit-managementID.json`, preserving unrelated Install/Add input without being blocked by it. Failure or interruption retains the record; enter Install/Add or that node's edit menu to continue, or use:

```bash
python3 deploy.py --resume
python3 deploy.py --resume --local-port 7901
python3 deploy.py edit NodeName --resume
python3 deploy.py install root@another-vps --fresh
```

Matching retries reuse saved input, with explicit flags taking precedence. Private-key contents and SublinkPro API keys are not copied into checkpoints. A 3x-ui admin token is held in the private part checkpoint during setup; success retains it in a local panel credential file as well as the server's protected maintenance credentials. **Direct subscription URLs and node links may contain credentials and are stored in private recovery files.** The directory is `0700`, files are `0600`, writes are atomic and share a process lock, and the whole directory is Git-ignored and excluded from VPS uploads. Each project retains one Install/Add workflow and a separate edit record per node. Only success of all enabled steps clears a record; Check and Exit leave it intact. Bare `--resume` prioritizes Install/Add, otherwise resumes a single pending node edit; multiple edits require selecting a node. `edit --fresh` replaces only that node's saved input and cannot replace a transaction that has started writing resources.

SSH passwords live in `.deploy-state/ssh-auth-{target-hash}.json`; panel URLs and tokens live in `.deploy-state/panel-api-{management-ID}.json`. These are user-owned plaintext `0600` files in a `0700` directory, without encryption or system-keychain storage. SublinkPro credentials remain in the private `.env`; proxy credentials can also occur in sing-box configuration and protected recovery backups. Removing a configuration deletes its panel credentials; shared SSH credentials are retained by target.

Use **View -> select entry or remote relay -> Diagnose panel** to read panel/core versions, REALITY client-version limits, and original account/transport matches through the API without changing the panel or proxy configuration. An existing entry with no local token retrieves it over its bound SSH connection; the first login still needs its previously unsaved SSH password. The direct command is `python3 deploy.py inspect-panel ConfigurationName`. Sanitized results go to `.deploy-state/panel-report-{management-ID}.json`, excluding tokens, UUIDs and keys.

Once VPS installation has been verified, resume reads the VPS and retries adding resources without rerunning the installer; a changed installation ID stops recovery. Integration failure does not roll back the VPS. Airport and local-node settings are verified by API readback, while subscription fetching and detection remain asynchronous. New resources do not alter existing subscriptions' fixed selections.

### Local configuration and relays

Candidate configurations must pass the actual `sing-box check` before a `0600` backup, atomic replacement and LaunchAgent restart. Restart briefly interrupts connections; failure attempts rollback. External edits, port conflicts and shared references guard against accidental overwrite/deletion. Sensitive backups live beside the configuration as `.one-key-proxy-backup-*.json`. Check validates dotenv, OpenSSH, API authentication and enabled sing-box configuration without altering resources or restarting services.

Use **View → select configuration → Relay settings → Local relay** to choose whether that node needs a local relay and which managed node to use. Install/Add also offers local relay selection. CLI shortcuts remain available:

```bash
python3 deploy.py relay Residential --via US
python3 deploy.py relay SomeNode --direct
python3 deploy.py add root@your-vps --via US
```

Relay changes update sing-box `detour` and the SublinkPro remote node's `DialerProxyName`, preserving protocol, host, port and credentials. Chains are supported, cycles and self-reference are rejected, and referenced relays cannot be deleted. Local SS continues to use loopback. Subscription downloading is independent of the data relay. Failed relay changes retain `relaying` status; reopen that configuration's relay settings to continue.

### Server-side relays

Use **View → select exit B → Relay settings → Remote relay**, then select a managed entry VPS A. Each combination publishes a separate ordinary VLESS node: `client → A's 3x-ui → B → destination`. Combinations share A's REALITY port and transport settings but have independent accounts and user routes. The original A/B nodes and the global default outbound remain intact. Supported exits are compatible VLESS TCP/WS/gRPC with TLS or REALITY, plugin-free AEAD/2022 Shadowsocks, and SOCKS5. Cleartext VLESS and remote combinations as exits are rejected.

A needs 3x-ui **3.8.0+ within 3.x**, admin API permissions and a uniquely matched VLESS REALITY Vision source. The TUI can fill missing source, SSH and server management before continuing the saved operation. Project installations reuse their runtime/token; manual installations use the independent component with a privately entered admin token. Existing client and inbound identities are verified. An insufficient version offers an immediate update and resumes the original operation, reusing saved names, ports and API input. SSH passwords are retained in private local credential files; private-key contents are not copied.

Creation saves a draft immediately after entry selection, checkpointing every name, residential setting, local SS port, and SSH answer. After interrupted input or failed SSH, return to B → Relay settings → Remote relay and choose Resume. Before remote writes, Edit SSH settings and Start over are also available. After confirmation, resuming keeps the same management ID and transaction without repeating confirmed input. Export recreates a missing runtime lock directory after reboot and distinguishes authentication, runtime files, installation state, and lock contention failures. Local adoption alone does not mean the server was installed by this project.

The default base name is `B(A中转)`, with `[SM]` added for SublinkPro and ` - 本地` appended for optional local SS. The local SS outbound connects only to A. Default names follow A/B renames and exit replacements, including both published display names and managed dialer references. Rename through the combination's relay settings to retain a manual name across source renames, syncs and exit replacements. Linked renames share a recoverable transaction; conflicts and unmanaged references block the change. IDs, accounts, connection parameters and sing-box tags remain unchanged. A name-only edit needs no entry connection or sing-box/Xray reload.

```bash
python3 deploy.py remote-relay Residential --entry US --no-local-node
python3 deploy.py remote-sync 'Residential(US中转)'
python3 deploy.py edit 'Residential(US中转)' --node-name 'US residential'
python3 deploy.py remote-relay 'US residential' --exit-node AnotherExit
python3 deploy.py remove 'US residential'
```

Changing B's remote link or syncing its subscription updates dependent combinations. Renaming a standalone node, changing its residential tag, or editing its local SS or local outbound does not sync the entry and can finish while the entry is offline. Subscription fingerprint changes require explicit reselection; there is no background relay refresh. Pending combination changes retain their original parameters; submit new parameters after finishing the original operation. Unavailable exits fail without falling back to A's direct IP. 3x-ui applies changes live where possible and may briefly restart Xray. Existing API/blocking rules keep their priority; B controls final destination connections and domain resolution.

New accounts remain disabled until the template, runtime route and exit connectivity have been verified. Private `0600` journals on A (`/etc/one-key-proxy/remote-relays/`) and the client (creation drafts in `.deploy-state/remote-create-*.json`, publication in `.deploy-state/remote-relay-*.json`) retain partial progress and may contain proxy credentials. Resume from the original exit's remote relay menu or from registered combination details. Failed creation before local publication can also be cancelled by deleting it. Deletion needs A online and cleans only owned client/outbound/routing resources; offline deletion retains progress. Referenced A/B nodes cannot be deleted, and server reconfiguration/uninstallation requires clearing its combinations first.

### Update panels

Main menu **5. Update panels**, also available as `python3 deploy.py update-panels`, lists separate current and target versions for 3x-ui and Xray. Panels use the latest stable release within their current major; Xray uses the latest available official numeric release within the compatibility limit. All eligible updates are selected by default, including core-only adjustments when the panel is already current. Incompatible newer cores are downgraded to the compatible target. Toggle `[x]` with space/comma-separated numbers, then choose `u` and confirm. Multiple configurations on the same server share one update. Missing SSH, failed detection or an unavailable compatible core prevents selection; `d NUMBER` fills SSH before another scan. Source and API management are not prerequisites for updating.

`MIN_PANEL_VERSION` in `lib/panel_version.py` remains `3.8.0`. Panels have no update ceiling; prereleases, development builds, downgrades and automatic major changes are excluded. The independent `MAX_XRAY_VERSION = '26.7.28'` limits cores because sing-box REALITY cannot meet Xray 26.9.8+'s ML-KEM handshake requirement. The source comment links [upstream issue #4520](https://github.com/SagerNet/sing-box/issues/4520); remove the core ceiling only after the fix and end-to-end verification. Xray also marks older numeric releases as prereleases, so core selection accepts those official numeric tags while excluding alpha/beta/RC tags and drafts. Updating 2.x to its latest 2.x still cannot satisfy remote relay's 3.x requirement; major migration is manual. Missing API versions fall back to the server binary; unknown versions are distinct from insufficient versions.

Remote relay creation, changes and sync check both panel and Xray versions and offer an immediate update before continuing when either is unsupported. Editing or filling management for a manually installed panel currently offers updates for unsupported panel versions only; it does not independently check the Xray compatibility range. Use the main panel-update menu to adjust the core when needed. Name, residential-tag and local-node edits do not check server versions.

Automatic updates support standard Linux systemd installations at `/usr/local/x-ui` with SQLite at `/etc/x-ui/x-ui.db`, including manual installations. Both official assets are downloaded and checked for SHA-256 and binary version before replacement. The selected core must also accept the existing runtime configuration. Service configuration, access paths, databases and existing nodes are retained; the selected compatible core replaces the bundled one. New installations apply the same core policy. Core-only changes skip database migration. Proxy traffic pauses briefly. Protected program/core/database backups and recovery journals live under `/etc/one-key-proxy-panel`. Failed panel or core startup and health checks restore the original installation; incomplete backups are never restored. Interrupted updates can be recovered from the panel menu or while resuming the original workflow. Existing Docker, OpenRC, external-database and custom-path installations require their original update tools.

### Delete configurations

`.deploy-state/managed.json` persists independently of the cleared recovery file. It records management/resource IDs, tags, fingerprints, paths and states, without proxy passwords, raw VLESS URIs, subscription tokens or API keys. Existing adopted configurations retain their records.

```bash
python3 deploy.py list
python3 deploy.py list --interactive
python3 deploy.py remove <management-id-or-name>
```

Delete previews and confirms removal of owned sing-box listeners/outbounds/routes, SublinkPro airports and imported nodes, companion local SS nodes, and adopted manual remote nodes. **Ordinary configurations need no connection to the expired VPS**; remote combinations need their entry online to clean server resources. Neither operation uninstalls the server. External references block deletion. Interrupted deletion retains a `deleting` record; repeat to reconcile remaining resources, clearing the record only after completion.

### Explicit adoption

`python3 deploy.py adopt manifest.json` accepts a user-owned `0600` manifest. It contains `groups` (each with `name`, `inbound`, `outbound`, `airport_id`, `remote_node_id`, `local_node_id`, and `relay`), explicit `remove_inbounds` / `remove_outbounds` lists, and `default_outbound`. `relay` names another group in the same manifest; manually managed remote nodes use a null `airport_id`.

Adoption verifies local SS credentials, remote settings and existing relay relationships before journaling the change, marking SublinkPro ownership, and rewriting all named sing-box references in one reload. SublinkPro display names and connection parameters remain intact. Adopted IDs are assigned locally and do not claim installer ownership of the VPS. Their resources can be managed through `relay` and `remove` without SSH, including removal of manually managed remote nodes.

Repeat the same manifest after interruption; unexpected external changes stop recovery. Sensitive `0600` backups under `.deploy-state/adoption-*.json` contain original proxy configuration and remain Git-ignored. Resource deletion does not affect the built-in templates.

## Before installation

### NAT VPS mode

Create these three **TCP** mappings in the provider portal before running the installer:

| Service | Example | Meaning |
| --- | --- | --- |
| Panel HTTPS | `56664:2053` | External `56664` to VPS `2053` |
| VLESS inbound | `56665:443` | External `56665` to VPS `443` |
| Subscription HTTPS | `56666:2096` | External `56666` to VPS `2096` |

Prompts show default internal ports: panel `2053`, VLESS `443`, subscription `2096`. Enter only the external port (panel `56664` means `56664:2053`), or provide the full mapping to override the internal port. The first setup requires the provider-assigned external port. When editing, Enter retains the current mapping and an external-only value retains the current internal port. The `.env` keys `OKP_PANEL_MAP`, `OKP_NODE_MAP`, and `OKP_SUB_MAP` support the same shorthand.

The required inputs are the public IPv4 address and those three `external:internal` mappings. UDP is not required. The installer cannot create provider-side NAT rules. After the public IP changes, run `update-address` and re-import the subscription or node.

NAT mode serves both the panel and subscription over HTTPS using a ten-year RSA-2048 self-signed certificate whose SAN contains the current IPv4 address. There is no HTTP fallback.

The final state is HTTPS-only. However, the official 3x-ui installer starts its service before this project can immediately bind the panel to loopback and configure TLS, leaving a possible brief initial HTTP exposure window. If the installer fails, the script first tries to confine any residual panel to `127.0.0.1`; if that cannot be confirmed, it stops x-ui. During installation, still restrict the provider firewall/security-group panel mapping to your management IP and relax it only after success if necessary.

### Regular VPS mode

Prepare one fully qualified subdomain managed by AliDNS, such as `hk1.example.com`, plus a dedicated Aliyun RAM AccessKey ID and AccessKey Secret. The ACME email is optional.

Default TCP ports, editable on the review screen, are:

| Service | Default |
| --- | --- |
| VLESS inbound | `443/tcp` |
| Panel HTTPS | `2053/tcp` |
| Subscription HTTPS | `2096/tcp` |

The installer creates or validates the A record and can optionally create an AAAA record when a usable IPv6 address is detected. When IPv6 is disabled, it deletes only project-owned AAAA records and stops if any AAAA record remains, preventing the name from publishing a stale IPv6 address. It refuses conflicting records; an identical unowned record is reused only after confirmation and remains outside project ownership. DNS-01 validation means no separate `80/tcp` opening is required for ACME.

## Minimum AliDNS RAM actions

Use a dedicated RAM user, never an Alibaba Cloud account AccessKey. The minimum action set needed to discover the zone, inspect records, manage the published record, and let acme.sh create/delete DNS-01 TXT records is:

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

Where supported by your AliDNS RAM policy, further restrict resources to the DNS zone being managed. Credentials are stored in a root-only directory because unattended certificate renewal needs them. They are excluded from the result file and normal logs.

## Interaction and output

The installer asks you to choose NAT or regular VPS mode, collects only mode-specific values, generates the remaining values, and performs its preflight. The REALITY target must resolve and complete a TCP connection and trusted TLS handshake. A final numbered review screen allows edits and requires another confirmation before 3x-ui, DNS, TLS, or firewall configuration begins.

The bootstrap is the exception: if download tools are missing, it installs minimum prerequisites through the system package manager before the review; on Arch Linux this invokes `pacman -Syu`. After final confirmation, RHEL-family Fail2ban setup may also try to install `epel-release` on a best-effort basis. Failure is reported as a degraded protection warning rather than a core deployment failure.

The standard `bootstrap.sh` intentionally starts the main installer with a clean environment and does not forward arbitrary `OKP_*` configuration variables. The local SSH launcher provides allowlisted defaults through an explicit `--defaults-file`. All deployment values still require interactive confirmation; there is no unattended `--yes` mode.

If an unmanaged 3x-ui installation already exists, the tool stops without taking ownership. Re-running the same bootstrap after an interrupted project-owned installation strictly validates the stage name, completion timestamp, and applicable live postconditions before resuming. A recovery transaction is written before the first official-installer invocation; binary-only and result-written-before-service interruptions are replayed with the same version and configuration only after the confirmed identity is checked and residual service activity is stopped and disabled. An abandoned initialization state is removed only when no stage marker, certificate, or 3x-ui resource exists; ambiguous cases stop for diagnosis.

On success, the terminal and `/root/one-key-proxy-result.txt` include:

- 3x-ui version and service status;
- panel URL, username, and password;
- external/internal TCP port mappings;
- raw Base64, Xray JSON, and Clash/Mihomo subscription URLs;
- the full VLESS URI;
- maintenance commands, backup location, and any degraded checks.

When the optional `qrencode` utility is available, the QR code is displayed only in the current terminal and is not written to the result file. The result file is mode `0600`. It never contains the Aliyun AccessKey Secret, management API token, REALITY private key, or TLS private key.

## Maintenance

Run `one-key-proxy` without arguments for the Chinese maintenance menu. Stable commands include:

```text
info                  show deployment information
status                check the service, internal TCP listeners, certificate, and stage markers
doctor                check the management API/token, inbound, Host, Xray, panel/subscription settings,
                      certificate identity, and Fail2ban
backup, restore
update-3xui, self-update, update-address
reconfigure-ports, reconfigure-domain, renew-cert
rotate-panel, rotate-token, rotate-client, remove-client
uninstall
```

Neither this project nor 3x-ui is updated automatically in the background. Regular VPS mode retains automatic certificate renewal, but **no DDNS task is installed**. A/AAAA records change only during initial setup or an explicitly requested address/domain reconfiguration.

`update-3xui` also selects the latest stable panel release within the current major and the latest compatible Xray, using SHA-256 verified official archives while retaining the existing panel path and service configuration. It journals and backs up programs, cores and databases before replacement. Failed startup or project health checks restore the original version and project state. Subsequent maintenance settles interrupted updates first; protected backups remain available for diagnosis or restore.

Domain, NAT public-IP, and certificate identity changes use a recoverable two-phase TLS state. Every maintenance operation first checks an interrupted transition against the certificate SAN and saved identity: it restarts x-ui and retains the transaction for the original operation when the new certificate is present, clears an unused transaction when the old certificate remains, or stops when neither can be proven. Active state is cleared and the result file refreshed only after the new identity passes local HTTPS/API and Xray health checks.

## Backup, restore, and removal warnings

- Full backups contain the 3x-ui database, management token, AliDNS credentials, and certificate private keys. Treat a backup leak as a server credential leak.
- Backups are stored in `/var/backups/one-key-proxy`, are mode `0600`, and the newest five are retained by default.
- Version 1 only guarantees restoration on the same server that created the backup; cross-server migration is not supported.
- Restore stops and restarts services and requires a network review when current values differ from the backup.
- Uninstall is itemized. A verified full backup is mandatory before removing any selected component.
- DNS records and firewall rules are removed only after ownership verification.
- Uninstall never deletes backups. Its pre-removal backup remains in the backup directory until an administrator removes it manually.

## Security notes and limitations

- The panel path is fixed to `/` and is easily scanned. Keep the generated strong password safe and check updates proactively.
- Skipping NAT certificate verification permits man-in-the-middle attacks; compare the result's SHA-256 fingerprint independently. A NAT IP change also invalidates the certificate SAN, subscription URLs, and node address until a manual update.
- Certificate renewal is not DDNS. Public address changes always require `update-address`.
- The REALITY preflight proves only that DNS, TCP, and trusted TLS work at that time; it cannot guarantee long-term availability or suitability as a camouflage target on every network.
- If a future latest stable 3x-ui release breaks the required API contract, the tool stops safely and keeps the installed panel; it never performs an unverified downgrade.
- The official 3x-ui installer at the pinned commit is still trusted root code. Asset digests, helper pinning, and downloader-shape checks reduce supply-chain drift; they cannot prove arbitrary upstream shell code is benign.
- Fail2ban may degrade to a warning on some distributions. RHEL derivatives try EPEL on a best-effort basis; uninstall does not remove the shared EPEL repository or Fail2ban package.
- Raw nftables/iptables rules are not modified automatically; follow the printed instructions to allow the internal TCP ports.
- Backups are designed for same-server recovery, not migration.
- Redacted operational logs are written to `/var/log/one-key-proxy.log` with mode `0600`.

See [DESIGN.md](DESIGN.md) for the complete state machine, ownership rules, and security model.

## Development

Requires Bash, Python 3.9+, ShellCheck, and common Unix test utilities.

```bash
git clone https://github.com/smallmain/one-key-proxy.git
cd one-key-proxy
```

Run ShellCheck:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck
shellcheck one-key-proxy
```

Run tests:

```bash
bash tests/run.sh
```

Both checks should pass before submitting a change. Real AliDNS, ACME, systemd/OpenRC, NAT, and firewall behavior must also be integration-tested on disposable VPS/VM instances.

## License

[MIT](LICENSE)
