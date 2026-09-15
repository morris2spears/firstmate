#!/usr/bin/env bash
# Manage the canonical per-Firstmate-home Cipher repository registrations.
#
# `list` prints effective exact owner/repository names, one per line. `inspect
# --json` and `validate --json` provide the stable machine-readable interface
# for operators and Cipher's consumer. `add` is explicit enrollment and
# normalizes case; `remove` refuses while this home has matching PR task
# metadata, so an in-flight gated request cannot become ordinary merge work.
# `rollback` atomically restores the registration set saved before the latest
# successful mutation and applies the same in-flight removal check before any
# write. All commands resolve FM_HOME, FM_CONFIG_OVERRIDE, and
# FM_STATE_OVERRIDE in the same way as the hook, watcher, and merge paths.
#
# Usage:
#   fm-cipher-repositories.sh list [--json]
#   fm-cipher-repositories.sh inspect [--json]
#   fm-cipher-repositories.sh validate [--json]
#   fm-cipher-repositories.sh add <owner/repo>
#   fm-cipher-repositories.sh remove <owner/repo>
#   fm-cipher-repositories.sh rollback
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON=${FM_CIPHER_PYTHON:-python3}

command -v "$PYTHON" >/dev/null 2>&1 || {
  echo "error: Cipher repository registration requires python3" >&2
  exit 2
}
exec "$PYTHON" "$SCRIPT_DIR/fm_cipher_repositories.py" "$@"
