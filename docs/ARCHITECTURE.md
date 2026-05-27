# Architecture

## Overview

Bull is a bash toolkit that creates, manages, and configures pentest VMs
(Kali Linux and Parrot Security) via Vagrant. It supports both an
interactive TUI (menu-driven) and a CLI mode.

## Directory Layout

```
Bull/
├── bull.sh                 Entry point (TUI + CLI dispatch)
├── lib/
│   ├── core.sh             Colors, logging, dependency checks, GPG encryption
│   ├── inventory.sh        VM inventory CRUD (JSON via jq)
│   ├── vagrant.sh          Vagrant/libvirt VM lifecycle (create, start, stop, destroy)
│   ├── vpn.sh              VPN configuration + kill switch (OpenVPN, WireGuard)
│   └── toolkits.sh         Security toolkit installation + persistent registry
├── configs/
│   ├── Vagrantfile.template    Vagrant template with provider-specific blocks
│   ├── kali-provision.sh       Kali provisioning (runs inside VM as root)
│   ├── parrot-provision.sh     Parrot provisioning (runs inside VM as root)
│   ├── parrot-playbook.yml     Ansible playbook for Parrot
│   └── ansible-playbook.yml    Ansible playbook for Kali
└── docs/
    ├── ARCHITECTURE.md         This file
    └── ADDING_A_TOOL.md        Guide for adding tools to the toolkit manager
```

## Boot Sequence

```
bull.sh
  ├── source lib/core.sh          (colors, logging, validation, GPG)
  ├── source lib/inventory.sh     (JSON inventory)
  ├── source lib/vagrant.sh       (VM lifecycle)
  ├── source lib/vpn.sh           (VPN + kill switch)
  ├── source lib/toolkits.sh      (toolkit registry)
  ├── parse_arguments "$@"
  └── if no command → interactive_loop()
      else → execute_command()
```

## Key Design Decisions

### Provider Abstraction
Bull detects whether KVM (`/dev/kvm`) is available and sets
`BULL_PROVIDER` to `libvirt` or `virtualbox`. All provider-specific
logic lives in `lib/vagrant.sh` and `configs/Vagrantfile.template`.
The rest of the codebase is provider-agnostic.

### Credential Security
Passwords are encrypted with GPG (AES256, SHA512, 65M iterations) and
stored in `.credentials.gpg` per VM. The plaintext password only exists
in memory during provisioning and is wiped from environment variables
immediately after use. The Vagrantfile (which contains the password for
provisioning) is `chmod 600` and sanitized post-provision.

### WSL2 Support
Bull detects WSL2 via `/proc/version` and adjusts:
- `VAGRANT_CMD` → `vagrant.exe` (VirtualBox) or `vagrant` (libvirt)
- `BULL_HOME` → Windows filesystem for VirtualBox, Linux for libvirt
- PATH shims for `cmd.exe` / `powershell.exe` to satisfy Vagrant checks

### Inventory
VM metadata is stored in `data/inventory.json` (not committed). All
mutations go through `inventory_*` functions which use atomic
`mktemp` + `mv` writes to avoid corruption.

### Toolkit Registry
Saved toolkits live in `$BULL_HOME/toolkits.json`. Toolkits are
installed inside VMs via `git clone` over SSH (`vagrant ssh -c`).
URLs are validated against shell metacharacters before execution.

## Dependencies

| Dependency | Purpose |
|------------|---------|
| Vagrant 2.3+ | VM provisioning |
| VirtualBox or libvirt | Hypervisor |
| jq | JSON inventory manipulation |
| gpg | Credential encryption |
| ssh / sshpass | VM connections |
| curl or wget | Box downloads |
| openssl | Password generation |
