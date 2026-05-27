# Adding a Tool to Bull's Toolkit Manager

Bull's toolkit manager lets users save, install, and update security
tools on their pentest VMs. This guide explains how tools work internally
and how to contribute new installation patterns.

## How It Works

1. User saves a Git URL to the **registry** (`$BULL_HOME/toolkits.json`)
2. On install, Bull clones the repo into `/opt/toolkits/<name>` inside the VM
3. If the repo contains `install.sh`, Bull runs it automatically
4. If it contains `setup.py`, Bull installs Python requirements

## The Installation Flow (inside the VM)

```bash
# 1. Clone or update
sudo git clone "$REPO_URL" "/opt/toolkits/$REPO_NAME"

# 2. Auto-detect install method
if [[ -f install.sh ]]; then
    bash install.sh
elif [[ -f setup.py ]]; then
    pip3 install -r requirements.txt
fi
```

## Making Your Tool Bull-Compatible

If you maintain a security tool and want it to work with Bull's
"one-click install":

1. Add an `install.sh` at the repo root that handles dependencies
2. Make it idempotent (safe to run multiple times)
3. Use `apt-get install -y` for system packages
4. Don't require interactive input

### Example `install.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail

apt-get install -y python3 python3-pip 2>/dev/null || true
pip3 install -r requirements.txt 2>/dev/null || true

echo "[+] Tool installed to $(pwd)"
```

## Contributing a New Install Pattern

Currently Bull supports two patterns: `install.sh` and `setup.py`.
To add a new one (e.g., `Makefile`, `go install`):

1. Edit `lib/toolkits.sh`, function `install_toolkit()`
2. Add an `elif` block after the `setup.py` check:

```bash
elif [[ -f "\${INSTALL_DIR}/\${REPO_NAME}/Makefile" ]]; then
    echo "[BULL] Running make install..."
    cd "\${INSTALL_DIR}/\${REPO_NAME}"
    make install
fi
```

3. Test on a running VM: `bull toolkit <vm-name> <git-url>`
4. Open a PR with the change

## Don't / Do

| Don't | Do |
|-------|-----|
| Hardcode tool URLs in source | Use the toolkit registry (`toolkit_save`) |
| Run `git clone` without validation | Use `_validate_toolkit_url` first |
| Install as root without cleanup | `chown` back to the BULL user after install |
| Use `echo -e "${RED}..."` for output | Use `log_info` / `log_error` from core.sh |
| Skip error handling on `git clone` | Wrap in `if ! git clone ...; then log_error; fi` |
