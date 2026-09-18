#!/usr/bin/env bash
# init.sh — create the per-project files ai-pipeline needs, in the current repository.
# Never overwrites an existing file. Prints hints for .ai/validate.sh; it does not guess
# validation commands on its own.
set -Eeuo pipefail
TOOLKIT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
TPL="$TOOLKIT/templates"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ai-pipeline init: run this inside a git repository" >&2; exit 2; }
cd -- "$ROOT"

created=() kept=()
# put SRC DEST [MODE] — copy a template unless DEST exists.
put() {
  if [[ -e "$2" ]]; then kept+=("$2"); return; fi
  mkdir -p -- "$(dirname -- "$2")"
  cp -- "$1" "$2"
  [[ -n "${3:-}" ]] && chmod "$3" "$2"
  created+=("$2")
}
put "$TPL/pipeline.conf" .ai/pipeline.conf
put "$TPL/validate.sh" .ai/validate.sh 755
put "$TPL/ai-gitignore" .ai/.gitignore
put "$TPL/AGENTS.md" AGENTS.md
put "$TPL/CLAUDE.md" CLAUDE.md

echo "ai-pipeline init in $ROOT"
for f in "${created[@]}"; do echo "  created  $f"; done
for f in "${kept[@]}"; do echo "  kept     $f (already exists, not changed)"; done

# Hints only: the user decides the real commands.
hints=()
[[ -f Makefile ]] && hints+=("make targets: $(grep -oE '^[a-zA-Z0-9_-]+:' Makefile | tr -d : | head -8 | tr '\n' ' ')")
[[ -f package.json ]] && hints+=("package.json scripts: $(python3 -c 'import json;print(" ".join(json.load(open("package.json")).get("scripts",{})))' 2>/dev/null)")
[[ -f pyproject.toml || -f pytest.ini || -f setup.cfg || -d tests ]] && hints+=("python: python3 -m pytest -q -p no:cacheprovider")
[[ -f Cargo.toml ]] && hints+=("rust: cargo build && cargo test")
[[ -f go.mod ]] && hints+=("go: go build ./... && go test ./...")
[[ -f CMakeLists.txt ]] && hints+=("cmake: cmake -S . -B build && cmake --build build && ctest --test-dir build")
compgen -G "src/*/package.xml" >/dev/null || compgen -G "src/*/*/package.xml" >/dev/null \
  && hints+=("ROS 2 colcon workspace: see $TOOLKIT/examples/ros2-colcon/")
[[ -f .github/workflows/ci.yml || -d .github/workflows ]] && hints+=("CI config in .github/workflows/ shows the commands CI runs")
[[ -f CONTRIBUTING.md ]] && hints+=("CONTRIBUTING.md may list the required checks")

cat <<MSG

Next steps:
  1. Edit .ai/validate.sh: fill STEPS with this project's offline build/test commands,
     then delete its '# AI-PIPELINE: UNCONFIGURED' line. Check it with:
       ai-pipeline --validate-only
  2. Fill in the TODO sections of AGENTS.md (skip if it already existed).
  3. Optional: .ai/pipeline.conf (protected files, audit focus, report language).
  4. Let agy edit this folder: open it once in Antigravity or run any agy command
     here so it is registered as a project (ai-pipeline also creates one if needed).
  5. ai-pipeline doctor, then: ai-pipeline --task "…" --plan-only
MSG
if [[ ${#hints[@]} -gt 0 ]]; then
  echo; echo "Hints found in this repository (verify before using):"
  for h in "${hints[@]}"; do echo "  - $h"; done
fi
