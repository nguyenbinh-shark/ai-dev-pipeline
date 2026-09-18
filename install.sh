#!/usr/bin/env bash
# install.sh — put `ai-pipeline` on PATH via a symlink in ~/.local/bin (no sudo).
set -Eeuo pipefail
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
dest="${1:-$HOME/.local/bin}"
mkdir -p -- "$dest"
ln -sfn -- "$here/bin/ai-pipeline" "$dest/ai-pipeline"
echo "linked $dest/ai-pipeline -> $here/bin/ai-pipeline"
case ":$PATH:" in *":$dest:"*) ;; *) echo "note: $dest is not on PATH";; esac
