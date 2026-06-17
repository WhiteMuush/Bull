# Security Policy

## Scope

Bull is a **wrapper** that orchestrates Vagrant, VirtualBox/libvirt, and
provisioning scripts. Security reports should concern vulnerabilities in
Bull itself (e.g., command injection via toolkit URLs, credential leaks,
privilege escalation in the wrapper logic).

Vulnerabilities in the underlying tools (Vagrant, VirtualBox, libvirt,
Kali, Parrot) should be reported to their respective maintainers.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, use one of:

1. **GitHub Security Advisories** (preferred):
   Go to [Security > Advisories](https://github.com/WhiteMuush/Bull/security/advisories)
   and click "Report a vulnerability".

2. **Email**: Contact the maintainer via the email on their
   [GitHub profile](https://github.com/WhiteMuush).

You should receive an acknowledgment within 48 hours. A fix or mitigation
will be coordinated privately before any public disclosure.

## Security Design

- Passwords are encrypted with GPG (AES256 + SHA512, 65M iterations)
- VM credentials are never stored in plaintext
- `/home` is encrypted with ecryptfs inside VMs
- Default OS accounts are locked after provisioning
- Synced folders are disabled (no host filesystem exposure)
- Toolkit URLs are validated against shell metacharacters before SSH execution
- VPN kill switch blocks all non-VPN traffic via iptables
