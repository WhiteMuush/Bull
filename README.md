# Your Pentest VM Toolkit

Launch a fully-equipped pentest VM in seconds with pre-installed security tools, VPN protection, and encrypted storage.

## Features

- **Auto-provisioning** — Kali/Parrot ready to use
- **VPN kill switch** — Blocks traffic if VPN drops
- **Encrypted /home** — User data protected with ecryptfs
- **GPG credentials** — Passwords encrypted with AES256 (65M iterations)
- **Snapshot support** — Rollback before risky operations
- **Install and manage security tools** — Pre-installed toolkit with many pentest utilities, easily add more via the manager

## Requirements

- Linux with libvirt or VirtualBox
- Vagrant 2.3+, jq, sudo

WSL2 supported via libvirt.

## Quick Start

```bash
# Run as root
sudo ./bull.sh init

# Interactive menu
sudo ./bull.sh

# Or CLI
sudo ./bull.sh create my-vm --os kali
```

## ⚠️ Important: First Run

> **⚠️ First installation can take 10-15 minutes** depending on your internet speed. This includes:
> - Downloading and installing Vagrant (if not present)
> - Downloading the Vagrant box (~2-4 GB for Kali/Parrot)
> - Installing libvirt/VirtualBox dependencies
> - Installing the vagrant-libvirt plugin

Following dependencies may be installed:

- **Vagrant** — VM provisioning from HashiCorp
- **VirtualBox** — Oracle VM hypervisor (optional)
- **libvirt** — KVM/QEMU virtualization
- **qemu-kvm** — KVM kernel modules
- **OVMF** — UEFI firmware for secure boot
- **vagrant-libvirt** — Vagrant plugin for KVM
- **jq** — JSON processing
- **spice-vdagent** — Clipboard/resolution for SPICE
- **xdotool** — X11 automation

## Storage

- **Hypervisor**: VirtualBox (`~/VirtualBox VMs/`) or libvirt (`/var/lib/libvirt/images/`)
- **BULL data**: `~/.bull/` (inventory, credentials, GPG keys, toolkit registry)

### ⚠️ WSL2 — Disk space reclamation

WSL2 stores its entire Linux filesystem in a `.vhdx` file that **grows automatically but never shrinks on its own**. After destroying VMs, the disk space is freed inside WSL2 but Windows still sees the `.vhdx` at its peak size.

To reclaim the space on the Windows side:

```powershell
# 1. Shut down WSL2
wsl --shutdown

# 2. Compact the virtual disk (run as Administrator in PowerShell)
$vhdx = (Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
Optimize-VHD -Path $vhdx -Mode Full
```

> If `Optimize-VHD` is not available (requires Hyper-V), use `diskpart` instead:
> ```
> diskpart
> select vdisk file="C:\Users\<you>\AppData\Local\Packages\<distro>\LocalState\ext4.vhdx"
> compact vdisk
> exit
> ```

## Security

- Scripts require root with 700 permissions
- Passwords never stored in plaintext
- Credentials: GPG + AES256 + SHA512 (65M iterations)
- /home encrypted with ecryptfs
- Default OS accounts locked after creation
- VPN kill switch blocks non-VPN traffic
- Synced folders disabled

> **Note**: Technical measures only. Does not protect against user error or social engineering.

## Commands

```bash
sudo ./bull.sh help      # Run as root
bull help                # After init
```


## Licence

[**MIT**](https://github.com/WhiteMuush/Bull/blob/master/LICENSE)
