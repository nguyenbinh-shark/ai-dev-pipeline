#!/usr/bin/env bash
# doctor.sh — check that the CLIs ai-pipeline drives are installed, logged in and offer
# the configured models. Read-only; prints no secrets.
set -Euo pipefail
TOOLKIT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
ok=0
say() { printf '%-8s %s\n' "$1" "$2"; }
bad() { say "FAIL" "$1"; ok=1; }
newest() { compgen -G "$1" | sort -V | tail -n 1; }
find_bin() { local p="${2:-}"; [[ -n "$p" ]] || p="$(command -v "$1" 2>/dev/null || newest "$3")"; printf '%s' "$p"; }

for t in git python3 timeout sha256sum; do
  command -v "$t" >/dev/null && say ok "$t" || bad "$t not found"
done
CLAUDE="$(find_bin claude "${AI_CLAUDE_BIN:-}" "$HOME/.vscode/extensions/anthropic.claude-code-*-linux-x64/resources/native-binary/claude")"
AGY="$(find_bin agy "${AI_AGY_BIN:-}" "$HOME/.gemini/bin/agy")"
CODEX="$(find_bin codex "${AI_CODEX_BIN:-}" "$HOME/.vscode/extensions/openai.chatgpt-*-linux-x64/bin/linux-x86_64/codex")"

if [[ -x "$CLAUDE" ]]; then say ok "claude $("$CLAUDE" --version 2>/dev/null | head -1) ($CLAUDE)"; else bad "claude CLI not found (set AI_CLAUDE_BIN)"; fi
if [[ -x "$AGY" ]]; then
  n="$(timeout 60 "$AGY" models </dev/null 2>/dev/null | grep -c $'\t' || true)"
  if [[ "$n" -gt 0 ]]; then say ok "agy ($AGY): $n models available"
  else bad "agy ($AGY) lists no models: not logged in? run agy once interactively"; fi
  m="${AI_AGY_MODEL:-gemini-3.8-flash}-${AI_AGY_EFFORT-medium}"; m="${m%-}"
  timeout 60 "$AGY" models </dev/null 2>/dev/null | cut -f1 | grep -qxF -- "$m" \
    && say ok "agy model $m" || bad "agy model $m not offered (see: agy models)"
else bad "agy CLI not found (set AI_AGY_BIN)"; fi
if [[ -x "$CODEX" ]]; then
  if timeout 60 "$CODEX" login status </dev/null >/dev/null 2>&1; then say ok "codex ($CODEX) logged in"
  else bad "codex not logged in (run: codex login)"; fi
  cm="${AI_CODEX_MODEL:-gpt-5.6-sol}"
  if timeout 60 "$CODEX" debug models </dev/null 2>/dev/null > /tmp/.ai-doctor-codex.$$ \
     && python3 "$TOOLKIT/lib/pipeline_lib.py" check-codex-model /tmp/.ai-doctor-codex.$$ \
        "$cm" "${AI_CODEX_EFFORT:-medium}" >/dev/null 2>&1; then say ok "codex model $cm"
  else bad "codex model $cm / effort not offered (see: codex debug models)"; fi
  rm -f /tmp/.ai-doctor-codex.$$
else bad "codex CLI not found (set AI_CODEX_BIN)"; fi

if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  if [[ -x "$root/.ai/validate.sh" ]]; then
    grep -q '^# AI-PIPELINE: UNCONFIGURED' "$root/.ai/validate.sh" \
      && bad "$root/.ai/validate.sh not configured yet" || say ok ".ai/validate.sh configured"
  else say info "no .ai/validate.sh in $root (run: ai-pipeline init)"; fi
fi
exit $ok
