# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Local Python/OpenSSH deployment with a Git-ignored `.env`, allowlisted installation defaults, built-in SublinkPro airport defaults and independent airport/node names.
- Companion Surge local Shadowsocks nodes with independent random passwords, matching sing-box listeners, user-supplied ports and repeatable updates that retain credentials and tags.
- Configuration management menu for install, add via SSH or subscription URL, delete, view and environment checks; relay settings live inside each configuration's details.
- Unified `ENABLE_LOCAL_NODE` control for sing-box and SublinkPro local nodes, without external template IDs or tags; `add` replaces the former `sync` command with a compatibility alias.
- Explicit SSH password login through the wizard or `--password`, with native hidden terminal input and authentication before upload over a shared connection.
- Immediate checkpoints for unfinished local workflows, menu/CLI resume, retained names and ports across failed syncs, and automatic record removal after success; passwords and API credentials are excluded.
- Built-in sing-box templates with validated atomic updates, protected backups and launchd reload/rollback, plus persistent ownership inventory and offline-VPS cleanup guarded against shared references.
- Explicit adoption and readable sing-box tags for existing proxies, synchronized relay selection for sing-box/SublinkPro, cycle prevention, and managed cleanup of manual remote nodes.
- Trusted-TLS reachability preflight for the selected REALITY target.
- Recoverable two-phase TLS identity transitions for maintenance reconfiguration and renewal.

### Changed

- NAT port prompts show internal defaults and accept external-only input, including dotenv mappings; edits retain the current internal port and allow Enter to keep the current mapping.
- IPv6-disabled AliDNS deployments remove only owned AAAA records and refuse to continue while any AAAA remains.
- Stage markers now require an exact stage name and valid completion timestamp; resource-free abandoned initialization state is recovered conservatively.
- Failed official 3x-ui installation is confined to loopback when possible and otherwise stops x-ui.
- Maintenance updates journal and restore the fixed `/` panel path offline before the first post-update local API call; failed recovery leaves x-ui stopped with the journal and backup retained.
- Initial 3x-ui installation journals binary-only and result-before-service interruption windows and supervises the official installer process group for graceful termination.
- Documentation now reflects the clean bootstrap environment, the exact `status`/`doctor` diagnostic scopes, and the manual real-VPS release gate.

### Security

- 3x-ui release assets require and verify the official SHA-256 digest; upstream installer curl requests for `main` files are pinned to the same release commit.
- Initial installation and maintenance updates check the adapted PATH-curl asset/helper download shape for compatibility drift; the pinned official installer commit remains an explicit root trust boundary.

## [0.1.0] - 2026-08-20

### Added

- Initial interactive installer for NAT and regular VPS deployments.
- Latest-stable 3x-ui installation with a VLESS + TCP + REALITY + XTLS-Vision inbound.
- NAT external/internal port publishing and IP self-signed HTTPS certificates.
- AliDNS record management and DNS-01 certificate issuance for regular VPS instances.
- Resumable installation stages, diagnostics, backups, same-server restore, credential rotation, and itemized removal.
- ShellCheck and unit-test CI workflow.

[Unreleased]: https://github.com/smallmain/one-key-proxy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/smallmain/one-key-proxy/releases/tag/v0.1.0
