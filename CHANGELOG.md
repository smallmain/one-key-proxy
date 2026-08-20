# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Trusted-TLS reachability preflight for the selected REALITY target.
- Recoverable two-phase TLS identity transitions for maintenance reconfiguration and renewal.

### Changed

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
