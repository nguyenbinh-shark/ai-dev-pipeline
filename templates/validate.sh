#!/usr/bin/env bash
# AI-PIPELINE: UNCONFIGURED  (delete this line once STEPS below are filled in)
#
# validate.sh — offline validation run by ai-pipeline after every implementation/fix.
# The pipeline runs it; the agents never do. Nothing here may need a network service,
# real hardware or a login.
#
# Usage: .ai/validate.sh <out_dir>
#   Writes <out_dir>/<step>.log for each step and <out_dir>/summary.json.
#   Exit code: 0 if every step passed, 1 otherwise, 2 on usage error or no STEPS.
set -Euo pipefail

# One entry per step: "name|timeout_seconds|command". Commands run from the repository
# root, in a fresh bash. Use this repository's real build/lint/test commands.
STEPS=(
  # "build|1800|make -j4"
  # "lint|600|ruff check ."
  # "test|1200|python3 -m pytest -q -p no:cacheprovider"
)
# Steps that must pass for later steps to make sense (later ones are SKIPPED).
GATE_STEPS=(build)
# 1 = run each step with an empty environment (only HOME, USER, LANG, TERM, PATH), so
# the user's shell setup cannot leak in; 0 = inherit the caller's environment.
CLEAN_ENV=1
PATH_FOR_STEPS="/usr/local/bin:/usr/bin:/bin"
# Shell code run before every step, e.g. "source ./venv/bin/activate" or
# "source /opt/ros/humble/setup.bash".
SETUP=""

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: $0 <out_dir>" >&2
  exit 2
fi
if [[ ${#STEPS[@]} -eq 0 ]]; then
  echo "validate.sh: no STEPS configured" >&2
  exit 2
fi

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUT="$1"
mkdir -p -- "$OUT"
OUT="$(cd -- "$OUT" && pwd)"

results="$OUT/results.tsv"
: > "$results"
blocked=""

for entry in "${STEPS[@]}"; do
  IFS='|' read -r name limit cmd <<< "$entry"
  log="$OUT/$name.log"
  if [[ -n "$blocked" ]]; then
    echo "skipped: $blocked failed" > "$log"
    printf '%s\t%s\t%s\t%s\n' "$name" "SKIPPED" "-1" "0" >> "$results"
    echo "[validate] $name: SKIPPED ($blocked failed)"
    continue
  fi
  full="${SETUP:+$SETUP && }$cmd"
  start=$SECONDS
  if [[ $CLEAN_ENV -eq 1 ]]; then
    env -i HOME="$HOME" USER="${USER:-}" LANG="${LANG:-C.UTF-8}" TERM=dumb PATH="$PATH_FOR_STEPS" \
        timeout --kill-after=30 "$limit" \
        bash --noprofile --norc -c 'cd -- "$1" && eval "$2"' _ "$ROOT" "$full" > "$log" 2>&1
  else
    timeout --kill-after=30 "$limit" \
        bash --noprofile --norc -c 'cd -- "$1" && eval "$2"' _ "$ROOT" "$full" > "$log" 2>&1
  fi
  rc=$?
  secs=$((SECONDS - start))
  if [[ $rc -eq 0 ]]; then status=PASS; else status=FAIL; fi
  [[ $rc -eq 124 ]] && echo "[validate] timed out after ${limit}s" >> "$log"
  if [[ $rc -ne 0 ]]; then
    for g in "${GATE_STEPS[@]}"; do [[ "$g" == "$name" ]] && blocked="$name"; done
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$rc" "$secs" >> "$results"
  echo "[validate] $name: $status (rc=$rc, ${secs}s)"
done

python3 - "$results" "$OUT" <<'PY'
import json, os, sys
results, out = sys.argv[1], sys.argv[2]
steps = []
for line in open(results):
    name, status, rc, secs = line.rstrip("\n").split("\t")
    steps.append({"name": name, "status": status, "rc": int(rc), "seconds": int(secs),
                  "log": os.path.join(out, name + ".log")})
overall = "PASS" if all(s["status"] == "PASS" for s in steps) else "FAIL"
json.dump({"status": overall, "steps": steps}, open(os.path.join(out, "summary.json"), "w"),
          indent=2)
print(f"[validate] overall: {overall}")
sys.exit(0 if overall == "PASS" else 1)
PY
