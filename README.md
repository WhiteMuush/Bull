# Bull

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/WhiteMuush/Bull/actions/workflows/ci.yml/badge.svg)](https://github.com/WhiteMuush/Bull/actions/workflows/ci.yml)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/CONTRIBUTING.md)
[![Wiki](https://img.shields.io/badge/docs-wiki-blue.svg)](https://github.com/WhiteMuush/Bull/wiki)

**Bull** spins up a fully equipped, hardened pentest VM in one command. It wraps
Vagrant and your hypervisor (libvirt/KVM or VirtualBox) to build Kali or Parrot
machines that come locked down by default, VPN kill switch, encrypted home,
GPG-protected credentials, snapshots and a reusable toolkit manager.

<img width="1230" height="715" alt="Bull" src="https://github.com/user-attachments/assets/ee4b5fee-67b0-4897-91b7-08605b3a9a32" />

## Features

| Capability | What you get |
|---|---|
| **Auto-provisioning** | Kali or Parrot, ready to use out of the box |
| **VPN kill switch** | iptables drops all traffic if the VPN drops (OpenVPN & WireGuard) |
| **Encrypted /home** | user data protected with ecryptfs |
| **GPG credentials** | AES256 + SHA512 (65M-iteration s2k), passphrase-unlocked, never written to disk in plaintext |
| **Snapshots** | roll back before any risky operation |
| **Toolkit manager** | save Git-based tools once, install them on every new VM |
| **Cross-provider** | libvirt/KVM or VirtualBox, auto-detected; WSL2 supported |

## Quick start

```bash
# One-shot host setup (Vagrant + hypervisor, unattended)
sudo ./install.sh

# Initialize Bull and verify dependencies
sudo ./bull.sh init

# Create your first VM, then just run the menu
sudo ./bull.sh create my-vm --os kali
sudo ./bull.sh
```

> **First run takes 10-15 minutes:** it downloads the Vagrant box (~2-4 GB) and
> installs hypervisor dependencies. After `bull init` you can call `bull`
> directly instead of `./bull.sh`.

**Requirements:** Linux with libvirt/KVM or VirtualBox (WSL2 via libvirt),
Vagrant 2.3+, `jq`, `gpg`, `ssh`, `sudo`. The installer can pull in the rest.

## Common commands

```bash
sudo bull create my-vm --os kali --ram 4096 --cpu 2
sudo bull start my-vm
sudo bull connect my-vm
sudo bull snapshot my-vm pre-exploit
sudo bull vpn my-vm ~/vpn/config.ovpn
sudo bull restore my-vm pre-exploit
sudo bull destroy my-vm
```

Every command and flag: [CLI Reference](https://github.com/WhiteMuush/Bull/wiki/CLI-Reference).

## Documentation

The [**Wiki**](https://github.com/WhiteMuush/Bull/wiki) is the full manual:
[Installation](https://github.com/WhiteMuush/Bull/wiki/Installation),
[Usage Guide](https://github.com/WhiteMuush/Bull/wiki/Usage-Guide),
[CLI Reference](https://github.com/WhiteMuush/Bull/wiki/CLI-Reference),
[VPN & Kill Switch](https://github.com/WhiteMuush/Bull/wiki/VPN-and-Kill-Switch),
[Toolkit Manager](https://github.com/WhiteMuush/Bull/wiki/Toolkit-Manager),
[Architecture](https://github.com/WhiteMuush/Bull/wiki/Architecture),
[Security Model](https://github.com/WhiteMuush/Bull/wiki/Security-Model) and
[Troubleshooting](https://github.com/WhiteMuush/Bull/wiki/Troubleshooting).

In-repo: [Architecture](docs/ARCHITECTURE.md), [Adding a Tool](docs/ADDING_A_TOOL.md),
[Contributing](docs/CONTRIBUTING.md), [Security Policy](docs/SECURITY.md).

## Project layout

```
bull.sh          entry point (TUI + CLI dispatch)
install.sh       unattended host setup (Vagrant + hypervisor)
lib/
  core.sh        colors, logging, dependency checks, GPG encryption
  inventory.sh   VM inventory CRUD (JSON via jq)
  vagrant.sh     Vagrant/libvirt VM lifecycle
  vpn.sh         VPN configuration + kill switch
  toolkits.sh    toolkit installation + persistent registry
configs/         Vagrantfile template + per-OS provisioning scripts
docs/            architecture, contributing, security, tooling guides
```

## Security

Bull hardens every VM it creates: GPG-encrypted credentials, ecryptfs `/home`,
locked default OS accounts, disabled synced folders and an iptables VPN kill
switch. These are technical measures only, they do not protect against user
error or social engineering. See the
[Security Model](https://github.com/WhiteMuush/Bull/wiki/Security-Model) and
[SECURITY.md](docs/SECURITY.md) to report vulnerabilities.

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for setup,
conventions and the PR checklist.

## License

[MIT](LICENSE)
