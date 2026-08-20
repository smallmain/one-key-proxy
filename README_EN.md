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

## Before installation

### NAT VPS mode

Create these three **TCP** mappings in the provider portal before running the installer:

| Service | Example | Meaning |
| --- | --- | --- |
| Panel HTTPS | `56664:2053` | External `56664` to VPS `2053` |
| VLESS inbound | `56665:443` | External `56665` to VPS `443` |
| Subscription HTTPS | `56666:2096` | External `56666` to VPS `2096` |

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

The standard `bootstrap.sh` intentionally starts the main installer with a clean environment and does not forward arbitrary `OKP_*` configuration variables. Deployment values must be collected and confirmed through the interactive flow; there is no unattended `--yes` mode.

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

`update-3xui` journals recovery before running the official updater. Because the current 3x-ui v3.6 updater can randomize the deliberately fixed `/` panel path, the tool stops x-ui after the update, restores and reads back `/` through the local CLI while offline, and only then enables autostart, starts the service, and makes its first local 3x-ui API and Xray checks. After an interruption, the next maintenance operation runs this recovery first. A failed readback or health check leaves x-ui stopped with autostart disabled, while retaining both the journal and pre-update backup for diagnosis or restore.

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
