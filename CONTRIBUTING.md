# Contributing to Bull

Thanks for your interest in Bull! This guide covers local setup, code conventions, and the PR checklist.

## Local Setup

```bash
# Clone the repo
git clone https://github.com/WhiteMuush/Bull.git
cd Bull

# Check dependencies
sudo ./bull.sh init

# Optional: install ShellCheck for local linting
sudo apt install shellcheck   # Debian/Ubuntu
brew install shellcheck        # macOS
```

## Code Conventions

| Rule | Example |
|------|---------|
| Shebang | `#!/usr/bin/env bash` |
| Strict mode | `set -uo pipefail` (no `-e` in interactive code) |
| Variables | Always quoted: `"${var}"` |
| Functions | `snake_case`, prefixed by module: `inventory_add` |
| Globals | `BULL_*` prefix, `UPPER_CASE` |
| Internal functions | Prefixed with `_`: `_display_step` |
| Colors | Use `log_info` / `log_error` etc., never raw `echo -e ${RED}` |
| Guard | Every lib file starts with `[[ -n "${_BULL_<MOD>_LOADED:-}" ]] && return 0` |
| Language | All code, comments, log messages, and docs in English |

## Adding a New Feature

1. Create a feature branch: `git checkout -b feat/my-feature`
2. Make your changes in the appropriate `lib/*.sh` file
3. Run `bash -n` on every modified `.sh` file
4. Run `shellcheck` if available (CI will catch it either way)
5. Test with at least one provider (libvirt or VirtualBox)
6. Open a PR against `main`

For adding a new security tool to the toolkit manager, see [docs/ADDING_A_TOOL.md](docs/ADDING_A_TOOL.md).

## PR Checklist

- [ ] `bash -n` passes on all modified `.sh` files
- [ ] ShellCheck clean (or justified exclusions)
- [ ] Tested on at least one provider
- [ ] No credentials or secrets in the diff
- [ ] README/docs updated if user-facing behavior changed

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add WireGuard config import
fix: correct snapshot restore on libvirt
docs: update ARCHITECTURE diagram
ci: add bash syntax check job
chore: update .gitignore
refactor: extract VPN detection into helper
```

## Reporting Issues

Use the [bug report template](https://github.com/WhiteMuush/Bull/issues/new?template=bug_report.yml) and include:
- Bull version (`bull --version`)
- Provider (libvirt or VirtualBox)
- Host OS and bash version
- Steps to reproduce
