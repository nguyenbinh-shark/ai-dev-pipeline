#!/usr/bin/env python3
"""Helpers for scripts/ai-pipeline.sh: compact prompt inputs, token accounting,
repeated-finding detection and model preflight. Standard library only.

Every subcommand reads pipeline artifacts and prints to stdout; none modifies the
repository. Usage numbers are copied from the CLIs' own machine-readable output and
never estimated: a field a CLI does not report is recorded as null (N/A).
"""
import argparse
import json
import os
import re
import subprocess
import sys

PLAN_EXCERPT_SECTIONS = ("objective", "relevant files", "constraints",
                         "acceptance criteria", "out of scope")
ERROR_RE = re.compile(
    r"error|fail|traceback|exception|assert|undefined reference|no such file|fatal|"
    r"not found|timed out|killed|segmentation", re.I)
MAX_EXCERPT_LINES = 60
MAX_LINE_CHARS = 240


# ── plan ─────────────────────────────────────────────────────────────────────
def plan_sections(text):
    """Split a Markdown plan into {lower-case heading: (heading, body)} for '## '."""
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1).strip().lower()
            out[cur] = (m.group(1).strip(), [])
        elif cur is not None:
            out[cur][1].append(line)
    return {k: (h, "\n".join(v).strip()) for k, (h, v) in out.items()}


def cmd_plan_excerpt(a):
    text = open(a.plan).read()
    secs = plan_sections(text)
    # A plan without the compact format's file list (older or hand-written plan): pass
    # it whole rather than risk dropping something the fixer/auditor needs.
    if "relevant files" not in secs:
        print(text.strip())
        return
    print("\n\n".join(f"## {secs[n][0]}\n\n{secs[n][1]}"
                      for n in PLAN_EXCERPT_SECTIONS if n in secs))


def relevant_files(plan_path):
    secs = plan_sections(open(plan_path).read())
    body = secs.get("relevant files", ("", ""))[1]
    return [m for m in re.findall(r"`([^`\s]+)`", body) if "/" in m or "." in m]


def cmd_relevant_count(a):
    print(len(relevant_files(a.plan)))


# ── validation digest ────────────────────────────────────────────────────────
def load_steps(path):
    if path in ("", "-") or not os.path.exists(path):
        return {}
    return {s["name"]: s for s in json.load(open(path))["steps"]}


def excerpt(log_path):
    try:
        lines = open(log_path, errors="replace").read().splitlines()
    except OSError as e:
        return [f"(log unreadable: {e})"]
    hits = [i for i, l in enumerate(lines) if ERROR_RE.search(l)]
    keep = set()
    for i in hits:
        keep.update(range(max(0, i - 2), min(len(lines), i + 3)))
    idx = sorted(keep)[-MAX_EXCERPT_LINES:] if keep else \
        list(range(max(0, len(lines) - 40), len(lines)))
    out, prev = [], None
    for i in idx:
        if prev is not None and i != prev + 1:
            out.append("…")
        out.append(lines[i][:MAX_LINE_CHARS])
        prev = i
    return out


def cmd_digest(a):
    cur = json.load(open(a.summary))
    base = load_steps(a.baseline)
    rows, new = [], 0
    for s in cur["steps"]:
        name, st = s["name"], s["status"]
        bst = base.get(name, {}).get("status")
        if st == "PASS":
            if a.mode == "all":
                rows.append(f"- {name}: PASS")
            continue
        if bst in ("FAIL", "SKIPPED"):
            if a.mode == "all":
                rows.append(f"- {name}: {st} (pre-existing: {bst} at baseline)")
            continue
        new += 1
        if st == "SKIPPED":
            rows.append(f"- {name}: SKIPPED (an earlier step failed) — not run")
            continue
        rows.append(f"- {name}: {st} (rc={s.get('rc')}) — NEW FAILURE; log `{s.get('log')}`")
        if st == "FAIL":
            rows.append("```")
            rows.extend(excerpt(s.get("log", "")))
            rows.append("```")
    if a.mode == "new" and not new:
        rows.append("No new validation failures.")
    print("\n".join(rows))


# ── review helpers ───────────────────────────────────────────────────────────
def load_review(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}


def fmt_finding(sev, f):
    loc = f.get("file") or "?"
    if f.get("line") is not None:
        loc += f":{f['line']}"
    return (f"- [{sev}/{f.get('category')}] {f.get('title')} — {loc}\n"
            f"  {f.get('detail', '').strip()}\n  fix: {f.get('suggestion', '').strip()}")


def cmd_findings(a):
    r = load_review(a.review)
    sevs = ("critical", "major") if a.which == "blocking" else ("minor",)
    out = [fmt_finding(s, f) for s in sevs for f in r.get(s) or []]
    if a.which == "minor":
        out = [f"- {f.get('title')} — {f.get('file')}" for f in r.get("minor") or []]
    print("\n".join(out) if out else "(none)")


def cmd_affected(a):
    r = load_review(a.review)
    files = {f.get("file") for s in ("critical", "major") for f in r.get(s) or []}
    diff = subprocess.run(["git", "-C", a.root, "diff", "--name-only", a.base, a.cur],
                          capture_output=True, text=True, check=True).stdout.split()
    files.update(diff)
    files.discard(None)
    files.discard("")
    print("\n".join(f"- `{f}`" for f in sorted(files)) or "(none)")


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def same_finding(f, g):
    # The follow-up audit prompt tells Codex to copy an unresolved finding's title
    # verbatim, so identity is exact (normalised) title + file. No fuzzy matching:
    # near-identical titles of distinct findings must not trigger an escalation.
    return (norm(f.get("file")) == norm(g.get("file"))
            and norm(f.get("title")) == norm(g.get("title")))


def cmd_repeat_check(a):
    """Exit 10 if a blocking finding survived >= threshold consecutive fix attempts."""
    streaks_prev = []
    stuck = []
    for k in range(1, a.cycle + 1):
        r = load_review(os.path.join(a.run_dir, f"review-cycle-{k}.json"))
        cur = [f for s in ("critical", "major") for f in r.get(s) or []]
        streaks = []
        for f in cur:
            n = 0
            for g, gn in streaks_prev:
                if same_finding(f, g):
                    n = gn + 1
                    break
            streaks.append((f, n))
        streaks_prev = streaks
    for f, n in streaks_prev:
        if n >= a.threshold:
            stuck.append({"title": f.get("title"), "file": f.get("file"), "fix_attempts": n})
    print(json.dumps(stuck))
    sys.exit(10 if stuck else 0)


# ── usage accounting ─────────────────────────────────────────────────────────
def usage_agy(raw, log, models_tsv):
    d = json.load(open(raw))
    u = d.get("usage") or {}
    rec = {"input": u.get("input_tokens"), "output": u.get("output_tokens"),
           "thinking": u.get("thinking_tokens"), "cache": u.get("cache_read_tokens"),
           "total": u.get("total_tokens"), "actual_model": "unavailable",
           "status": d.get("status")}
    try:
        text = open(log, errors="replace").read()
        rec["model_requests"] = text.count(":streamGenerateContent")
        labels = re.findall(r'selected model override to backend: label="([^"]+)"', text)
        # agy logs the requested label even for a request it then rejects, so only a
        # successful run's label counts as the model actually used.
        if labels and d.get("status") == "SUCCESS":
            label = labels[-1]
            rec["actual_model"] = label
            for line in open(models_tsv):
                mid, _, lab = line.rstrip("\n").partition("\t")
                if lab == label:
                    rec["actual_model"] = mid
    except OSError:
        pass
    return rec


def usage_codex(raw):
    tot = {}
    for line in open(raw):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "turn.completed":
            for k, v in (e.get("usage") or {}).items():
                if isinstance(v, int):
                    tot[k] = tot.get(k, 0) + v
    return {"input": tot.get("input_tokens"), "output": tot.get("output_tokens"),
            "thinking": tot.get("reasoning_output_tokens"),
            "cache": tot.get("cached_input_tokens"), "total": None,
            "actual_model": "unavailable"}


def usage_claude(raw):
    d = json.load(open(raw))
    mu = d.get("modelUsage") or {}
    if not mu:
        return {"input": None, "output": None, "thinking": None, "cache": None,
                "total": None, "actual_model": "unavailable"}
    s = lambda k: sum(m.get(k, 0) for m in mu.values())
    main = max(mu, key=lambda m: mu[m].get("outputTokens", 0))
    others = sorted(m for m in mu if m != main)
    return {"input": s("inputTokens"), "output": s("outputTokens"),
            "thinking": s("thinkingTokens"), "cache": s("cacheReadInputTokens"),
            "cache_write": s("cacheCreationInputTokens"), "total": None,
            "actual_model": main + (f" (+{', '.join(others)})" if others else "")}


def cmd_usage_record(a):
    rec = {"agent": a.agent, "stage": a.stage, "requested_model": a.model or "cli-default",
           "effort": a.effort or "cli-default", "seconds": a.seconds}
    try:
        if a.kind == "agy":
            rec.update(usage_agy(a.raw, a.log, a.models_tsv))
        elif a.kind == "codex":
            rec.update(usage_codex(a.raw))
        else:
            rec.update(usage_claude(a.raw))
    except Exception as e:  # unreadable output: record the call, not invented numbers
        rec.update({"input": None, "output": None, "thinking": None, "cache": None,
                    "total": None, "actual_model": "unavailable",
                    "usage_error": str(e)[:200]})
    if a.warn_threshold and isinstance(rec.get("total"), int) \
            and rec["total"] > a.warn_threshold:
        rec["warning"] = (f"total_tokens {rec['total']} exceeds the expected ceiling "
                          f"{a.warn_threshold} for this task's scope")
        print(f"WARNING: {a.stage}: {rec['warning']}", file=sys.stderr)
    with open(a.out, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"{a.stage}: model={rec['requested_model']} effort={rec['effort']} "
          f"actual={rec['actual_model']} input={rec.get('input')} "
          f"output={rec.get('output')} total={rec.get('total')}")


def cmd_usage_table(a):
    recs = []
    if os.path.exists(a.usage):
        recs = [json.loads(l) for l in open(a.usage) if l.strip()]
    na = lambda v: "N/A" if v is None else f"{v:,}"
    rows = ["| Agent | Stage | Model (requested → actual) | Effort | Input | Output | "
            "Thinking | Cache read | Total |", "|---|---|---|---|---:|---:|---:|---:|---:|"]
    measurable, derived = 0, False
    for r in recs:
        tot = r.get("total")
        cell = na(tot)
        if tot is None and isinstance(r.get("input"), int) and isinstance(r.get("output"), int):
            tot, derived = r["input"] + r["output"], True
            cell = f"N/A ({tot:,}†)"
        if isinstance(tot, int):
            measurable += tot
        rows.append(f"| {r['agent']} | {r['stage']} | {r['requested_model']} → "
                    f"{r['actual_model']} | {r['effort']} | {na(r.get('input'))} | "
                    f"{na(r.get('output'))} | {na(r.get('thinking'))} | "
                    f"{na(r.get('cache'))} | {cell} |")
    count = lambda ag: sum(1 for r in recs if r["agent"] == ag)
    warnings = [f"- WARNING ({r['stage']}): {r['warning']}" for r in recs if r.get("warning")]
    out = ["## Token usage", "", *rows, "",
           f"- Total AI calls: {len(recs)}",
           f"- Gemini calls: {count('gemini')}",
           f"- Codex calls: {count('codex')}",
           f"- Claude calls: {count('claude')}",
           f"- Audit cycles: {a.cycles}",
           f"- Escalations: {a.escalations}",
           f"- Total measurable tokens: {measurable:,}"]
    if derived:
        out.append("")
        out.append("† The CLI reports no total; value is its reported input + output. "
                   "Codex `input` already includes `cache read`; for Gemini and Claude "
                   "cache reads are reported separately and not included.")
    reqs = [f"{r['stage']}={r['model_requests']}" for r in recs if "model_requests" in r]
    if reqs:
        out.append(f"- Gemini model requests per call (from agy log): {', '.join(reqs)}")
    if warnings:
        out += ["", *warnings]
    print("\n".join(out))


# ── model preflight ──────────────────────────────────────────────────────────
def cmd_check_agy_model(a):
    ids = [l.split("\t")[0] for l in open(a.models_tsv) if "\t" in l]
    want = f"{a.model}-{a.effort}" if a.effort else a.model
    if want not in ids:
        sys.exit(f"agy model '{want}' (model={a.model!r}, effort={a.effort!r}) is not in "
                 f"`agy models`: {', '.join(ids)}")
    print(want)


def cmd_check_codex_model(a):
    d = json.load(open(a.catalog))
    models = {m["slug"]: [l["effort"] for l in m.get("supported_reasoning_levels", [])]
              for m in d.get("models", [])}
    if a.model not in models:
        sys.exit(f"codex model '{a.model}' is not in `codex debug models`: "
                 f"{', '.join(models)}")
    if a.effort not in models[a.model]:
        sys.exit(f"codex model '{a.model}' does not support reasoning effort "
                 f"'{a.effort}' (supported: {', '.join(models[a.model])})")
    print(f"{a.model} {a.effort}")


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("plan-excerpt"); s.add_argument("plan"); s.set_defaults(f=cmd_plan_excerpt)
    s = sp.add_parser("relevant-count"); s.add_argument("plan"); s.set_defaults(f=cmd_relevant_count)
    s = sp.add_parser("digest"); s.add_argument("summary"); s.add_argument("baseline")
    s.add_argument("--mode", choices=("all", "new"), default="all"); s.set_defaults(f=cmd_digest)
    s = sp.add_parser("findings"); s.add_argument("review")
    s.add_argument("which", choices=("blocking", "minor")); s.set_defaults(f=cmd_findings)
    s = sp.add_parser("affected"); s.add_argument("review"); s.add_argument("root")
    s.add_argument("base"); s.add_argument("cur"); s.set_defaults(f=cmd_affected)
    s = sp.add_parser("repeat-check"); s.add_argument("run_dir")
    s.add_argument("cycle", type=int); s.add_argument("threshold", type=int)
    s.set_defaults(f=cmd_repeat_check)
    s = sp.add_parser("usage-record")
    for k in ("kind", "agent", "stage", "model", "effort", "raw", "out"):
        s.add_argument("--" + k, default="")
    s.add_argument("--log", default=""); s.add_argument("--models-tsv", default="/dev/null")
    s.add_argument("--seconds", type=int, default=0)
    s.add_argument("--warn-threshold", type=int, default=0); s.set_defaults(f=cmd_usage_record)
    s = sp.add_parser("usage-table"); s.add_argument("usage")
    s.add_argument("--cycles", default="0"); s.add_argument("--escalations", default="0")
    s.set_defaults(f=cmd_usage_table)
    s = sp.add_parser("check-agy-model"); s.add_argument("models_tsv"); s.add_argument("model")
    s.add_argument("effort"); s.set_defaults(f=cmd_check_agy_model)
    s = sp.add_parser("check-codex-model"); s.add_argument("catalog"); s.add_argument("model")
    s.add_argument("effort"); s.set_defaults(f=cmd_check_codex_model)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
