# Bull

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/WhiteMuush/Bull/actions/workflows/ci.yml/badge.svg)](https://github.com/WhiteMuush/Bull/actions/workflows/ci.yml)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/CONTRIBUTING.md)
[![Wiki](https://img.shields.io/badge/docs-wiki-blue.svg)](https://github.com/WhiteMuush/Bull/wiki)

Spin up a fully equipped, hardened pentest VM in one command. Bull wraps Vagrant and a hypervisor (libvirt/KVM or VirtualBox) to provision Kali or Parrot machines with a VPN kill switch, encrypted home, GPG-protected credentials, snapshots, and a reusable toolkit manager.

<img width="1230" height="715" alt="ScreenBull" src="https://github.com/user-attachments/assets/ee4b5fee-67b0-4897-91b7-08605b3a9a32" />

## Features

- **Auto-provisioning** — Kali or Parrot, ready to use out of the box
- **VPN kill switch** — iptables rules drop all traffic if the VPN drops (OpenVPN & WireGuard)
- **Encrypted /home** — user data protected with ecryptfs
- **GPG credentials** — passwords encrypted with AES256 + SHA512 (65M iterations), never stored in plaintext
- **Snapshots** — roll back before any risky operation
- **Toolkit manager** — save Git-based security tools once, install them on every new VM
- **Cross-provider** — libvirt/KVM or VirtualBox, auto-detected; WSL2 supported

## Requirements

- Linux with libvirt/KVM or VirtualBox (WSL2 supported via libvirt)
- Vagrant 2.3+, `jq`, `gpg`, `ssh`, `sudo`

The installer can pull in everything else for you.

## Quick Start

```bash
# One-shot host setup (Vagrant + hypervisor, unattended)
sudo ./install.sh

# Initialize Bull and verify dependencies
sudo ./bull.sh init

# Create your first VM
sudo ./bull.sh create my-vm --os kali

# Or just launch the interactive menu
sudo ./bull.sh
```

> **First run takes 10–15 minutes.** It downloads the Vagrant box (~2–4 GB) and installs hypervisor dependencies. See the [Installation guide](https://github.com/WhiteMuush/Bull/wiki/Installation) for details.

After `bull init` you can call `bull` directly instead of `./bull.sh`.

## Common Commands

```bash
sudo bull create my-vm --os kali --ram 4096 --cpu 2
sudo bull start my-vm
sudo bull connect my-vm
sudo bull snapshot my-vm pre-exploit
sudo bull vpn my-vm ~/vpn/config.ovpn
sudo bull restore my-vm pre-exploit
sudo bull destroy my-vm
```

Full command reference: [CLI Reference](https://github.com/WhiteMuush/Bull/wiki/CLI-Reference).

## Documentation

The [**Wiki**](https://github.com/WhiteMuush/Bull/wiki) is the full manual:

- [Installation](https://github.com/WhiteMuush/Bull/wiki/Installation) — host setup, providers, WSL2, disk reclamation
- [Usage Guide](https://github.com/WhiteMuush/Bull/wiki/Usage-Guide) — creating, managing, and connecting to VMs
- [CLI Reference](https://github.com/WhiteMuush/Bull/wiki/CLI-Reference) — every command and flag
- [VPN & Kill Switch](https://github.com/WhiteMuush/Bull/wiki/VPN-and-Kill-Switch) — how traffic is locked to the tunnel
- [Toolkit Manager](https://github.com/WhiteMuush/Bull/wiki/Toolkit-Manager) — save and deploy your own tools
- [Architecture](https://github.com/WhiteMuush/Bull/wiki/Architecture) — how Bull works internally
- [Security Model](https://github.com/WhiteMuush/Bull/wiki/Security-Model) — what Bull protects and what it does not
- [Troubleshooting](https://github.com/WhiteMuush/Bull/wiki/Troubleshooting) — common errors and fixes

In-repo references: [Architecture](docs/ARCHITECTURE.md), [Adding a Tool](docs/ADDING_A_TOOL.md), [Contributing](docs/CONTRIBUTING.md), [Security Policy](docs/SECURITY.md).

## Project Layout

```
bull.sh              Entry point (TUI + CLI dispatch)
install.sh           Unattended host setup (Vagrant + hypervisor)
lib/
  core.sh            Colors, logging, dependency checks, GPG encryption
  inventory.sh       VM inventory CRUD (JSON via jq)
  vagrant.sh         Vagrant/libvirt VM lifecycle
  vpn.sh             VPN configuration + kill switch
  toolkits.sh        Toolkit installation + persistent registry
configs/             Vagrantfile template + per-OS provisioning scripts
docs/                Architecture, contributing, security, tooling guides
```

## Security

Bull hardens every VM it creates: GPG-encrypted credentials, ecryptfs `/home`, locked default OS accounts, disabled synced folders, and an iptables VPN kill switch. These are technical measures only — they do not protect against user error or social engineering. See the [Security Model](https://github.com/WhiteMuush/Bull/wiki/Security-Model) and [SECURITY.md](docs/SECURITY.md) for reporting vulnerabilities.

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for setup, conventions, and the PR checklist.

## License

[MIT](LICENSE)
