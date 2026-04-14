# BULL — Pentest VM Provisioning

Automated toolkit to spin up fully-configured Kali Linux or Parrot Security VMs with built-in security hardening.

## What is BULL?

BULL creates encrypted pentest VMs in minutes with:
- Auto-provisioning — Kali/Parrot ready to use
- VPN kill switch — Blocks traffic if VPN drops
- Encrypted /home — User data protected with ecryptfs
- GPG credentials — Passwords encrypted with AES256 (65M iterations)
- Snapshot support — Rollback before risky operations
- Toolkit manager — Install and manage security tools

## Requirements

- Linux with libvirt or VirtualBox
- Vagrant 2.3+
- jq, sudo

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

## VM Storage

VMs are stored in the hypervisor's default location:
- VirtualBox: ~/VirtualBox VMs/
- libvirt: /var/lib/libvirt/images/

BULL stores its data in ~/.bull/ including the inventory, encrypted credentials, GPG keys, toolkit registry, and per-VM working directories.

## Compatibility

Tested on:
- Linux with libvirt (KVM/QEMU)
- Linux with VirtualBox
- WSL2 with libvirt

Not supported on macOS or Windows without WSL2.

## Security

- Scripts require root and have 700 permissions (owner only)
- Passwords never stored in plaintext on disk
- Credentials encrypted with GPG using AES256 + SHA512 with 65M key derivation iterations
- User /home directory encrypted with ecryptfs
- Default OS accounts (user/kali) are locked after VM creation
- VPN kill switch uses iptables to block all non-VPN traffic when connected
- Synced folders are disabled to prevent host file exposure

**Not a substitute for operational security.** This tool provides technical security measures but does not protect against user error, social engineering, or other attack vectors outside the scope of the toolkit.

## Commands

**init**
Checks and installs dependencies (vagrant, libvirt, jq, gnupg). Verifies the system can run VMs.

**create <name> [--ram MB] [--cpu N] [--resolution WxH] [--os kali|parrot] [--username USER]**
Creates a new VM with specified resources. If no options provided, interactive mode asks for OS choice (Kali or Parrot), credentials (username and password), keyboard layout, and display resolution. RAM defaults to 4096MB, CPU to 2 cores. Resolution defaults to 1920x1080. Username defaults to admin. The VM is fully provisioned with security tools, VPN packages, and working directories.

**list**
Shows all VMs managed by BULL with their status (running, stopped, not created), IP address if running, RAM allocation, CPU count, and whether VPN is configured. Displays information from the inventory database.

**start <name>**
Starts a stopped VM and waits for it to obtain an IP address from the network. Uses libvirt or vagrant depending on configured provider.

**stop <name>**
Gracefully shuts down a running VM. First attempts ACPI shutdown, waits up to 20 seconds, then forces power off if needed. Ensures clean VM shutdown to prevent data corruption.

**destroy <name>**
Permanently deletes a VM and all its associated files including disk images, configuration, and snapshots. Requires confirmation as this is irreversible. Cleans up both the hypervisor resources and BULL's inventory records.

**connect <name>**
Opens an SSH connection to the running VM using the stored credentials. The username and password are retrieved from the encrypted credentials file. Works with both libvirt and VirtualBox.

**view <name>**
Opens the VM in a graphical console. For libvirt, uses virt-viewer. For VirtualBox, opens the default VM viewer. Requires a display environment.

**snapshot <name> [label]**
Creates a named snapshot of the VM. If no label provided, prompts for one. Snapshots capture the entire VM state including disk contents, memory, and configuration. Useful before making system changes or running risky operations. Multiple snapshots can be kept for different restore points.

**restore <name> <label>**
Restores a VM to a previously saved snapshot. Current state is lost but can be recovered by creating a new snapshot first if needed. Restore is instant and replaces the current VM state with the snapshot data.

**vpn <name> <config.ovpn>**
Configures a VPN connection inside the VM using the provided OpenVPN configuration file. Installs OpenVPN if not present, copies the configuration, and sets up an iptables-based kill switch. The kill switch blocks all network traffic except through the VPN tunnel. If the VPN connection drops unexpectedly, all traffic is blocked to prevent IP leaks. Supports both OpenVPN (.ovpn) and WireGuard (.conf) configurations.

**toolkit <name> <git-url>**
Clones a Git repository into /opt/toolkits/ on the specified VM. If the repository contains an install.sh script, it is executed automatically. Useful for installing custom security tools, exploits, or utility scripts. The tool is cloned as root and then ownership is transferred to the VM user.

**toolkit (interactive)**
Opens the Toolkit Manager submenu with these options:

- **Install on VM (from URL)** — Prompts for a Git URL and a target VM, then clones and installs the repository on that VM.
- **Install from Library** — Shows saved toolkits in the local library and lets you select one to install on any VM.
- **Add to Library** — Saves a Git URL to the local toolkit registry with a custom name for quick access later.
- **Remove from Library** — Deletes a saved toolkit from the registry.
- **Manage Library** — Allows updating a toolkit on a VM (git pull), changing the Git URL, or renaming the toolkit entry.

The toolkit library stores URLs in ~/.bull/toolkits.json and is shared across all VMs.

**show-pass <name>**
Decrypts and displays the VM credentials. Shows the username and password which were encrypted with GPG during VM creation. The password is encrypted using AES256 with SHA512 key derivation (65 million iterations) for strong protection against offline attacks. Use this to retrieve credentials if forgotten.

**status**
Shows a global overview of all VMs including their state, resource usage, network configuration, and security status. Provides a quick summary of the entire BULL environment.

**sync**
Reconciliates the inventory with the actual state of VMs on the hypervisor. Detects VMs that were created or deleted outside of BULL and updates the internal inventory accordingly. Use this if the inventory appears out of sync with reality.
