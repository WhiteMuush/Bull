# tests/test_helper.bash - shared bootstrap for the Bull bats suite.
#
# Sources the source-only libraries into the test shell without launching
# the CLI or touching a real VM. Tests exercise pure helpers only.

BULL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export BULL_ROOT
export TERM="${TERM:-xterm}"

load_libs() {
    # shellcheck source=../lib/core.sh
    source "${BULL_ROOT}/lib/core.sh"
    # shellcheck source=../lib/vpn.sh
    source "${BULL_ROOT}/lib/vpn.sh"
}
