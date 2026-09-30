#!/usr/bin/env python3
"""The agent's progress records: port/agent/WORKBOOK.md (current state, task
checklist, log) and the status columns of port/agent/kernels.csv.  Keeping
them current lets anyone take over the port mid-way (port/agent/WORKFLOW.md,
"Workbook").

  workbook.py status [--phase N]          summary: current state, checklist and kernel progress
  workbook.py next                        the next open checklist items and todo kernels
  workbook.py set <key|kernel id|route:<name>> <todo|in-progress|done|blocked|n/a>
                  [--commit SHA] [--tests "T-AB-x W-20 PASS; ..."] [--note TEXT]
                                          update kernels.csv rows
  workbook.py check                       consistency check (run by port/gates/static.sh)
  workbook.py resume                      what a fresh session needs (about 60 lines): current state,
                                          next items, kernels in progress, last log entries, open blockers,
                                          the phase-card section to read
  workbook.py archive [--keep N]          move all but the last N (10) log entries to WORKBOOK_ARCHIVE.md

check verifies:
  - WORKBOOK.md has the sections and the "Current state" keys, and its
    "Last commit" exists in git
  - every ticked checklist item names an existing commit and its tests, and has
    a log entry whose heading contains its ID
  - kernels.csv statuses are valid; every 'done' row has an existing commit and
    tests; every 'blocked' row has a note
  - the CPU-view base is the original one or is listed in port/agent/REFACTORS.md
  - context budget (WORKFLOW.md section 11): WORKBOOK.md stays under 40000 characters
    (else: workbook.py archive) and each log entry under 25 lines
"""

import argparse
import csv
import io
import os
import re
import signal
import subprocess
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
REPO = os.path.dirname(PORT)
AG = os.path.join(PORT, "agent")
WB = os.path.join(AG, "WORKBOOK.md")
ARCH = os.path.join(AG, "WORKBOOK_ARCHIVE.md")
MAX_CHARS = 40000
MAX_ENTRY_LINES = 25
KC = os.path.join(AG, "kernels.csv")
STATES = ("todo", "in-progress", "done", "blocked", "n/a")
KEYS = ("Phase", "Current task", "Last commit", "Last gate passed", "Builds", "Dev references", "Blockers",
        "Next step")
ORIGINAL_BASE = "f8eae70b2acbf6585fe8629820e794cbe0705d93"


def commit_exists(sha):
    sha = sha.strip()
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        return False
    return subprocess.run(["git", "-C", REPO, "cat-file", "-e", sha + "^{commit}"],
                          capture_output=True).returncode == 0


def read_csv():
    return list(csv.DictReader(open(KC)))


def write_csv(rows):
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow(r)
    open(KC, "w").write(buf.getvalue())


def parse_wb():
    text = open(WB).read()
    secs = {}
    cur = None
    for line in text.split("\n"):
        m = re.match(r"^## (.+?)\s*$", line)
        if m:
            cur = m.group(1)
            secs[cur] = []
            continue
        if cur:
            secs[cur].append(line)
    state = {}
    for line in secs.get("Current state", []):
        m = re.match(r"^- ([^:]+):\s*(.*)$", line)
        if m:
            state[m.group(1).strip()] = m.group(2).strip()
    items = []
    group = ""
    for line in secs.get("Task checklist", []):
        if line.startswith("### "):
            group = line[4:].strip()
        m = re.match(r"^- \[( |x|X)\] (\S+)\s+(.*)$", line)
        if m:
            items.append(dict(done=m.group(1) != " ", id=m.group(2), text=m.group(3), group=group, line=line))
    logs = [l[4:] for l in secs.get("Log", []) if l.startswith("### ")]
    if os.path.exists(ARCH):
        logs = [l[4:] for l in open(ARCH).read().split("\n") if l.startswith("### ")] + logs
    return secs, state, items, logs


def log_entries(lines):
    """[(heading line, [lines])] of a Log section"""
    out = []
    for l in lines:
        if l.startswith("### "):
            out.append([l, []])
        elif out:
            out[-1][1].append(l)
    return out


def cmd_status(args):
    secs, state, items, logs = parse_wb()
    print("Current state:")
    for k in KEYS:
        print(f"  {k}: {state.get(k, '(missing)')}")
    print("\nChecklist:")
    groups = []
    for it in items:
        if it["group"] not in groups:
            groups.append(it["group"])
    for g in groups:
        gi = [i for i in items if i["group"] == g]
        print(f"  {sum(i['done'] for i in gi):3d}/{len(gi):<3d} {g}")
    rows = read_csv()
    print("\nKernels (kernels.csv):")
    secs_ = []
    for r in rows:
        if r["section"] not in secs_:
            secs_.append(r["section"])
    for s in secs_:
        rs = [r for r in rows if r["section"] == s]
        if args.phase and str(rs[0]["phase"]) != str(args.phase):
            continue
        c = {st: sum(1 for r in rs if r["status"] == st) for st in STATES}
        print(f"  phase {rs[0]['phase']} {s:5s} done {c['done']:3d}  in-progress {c['in-progress']:2d}  "
              f"todo {c['todo']:3d}  blocked {c['blocked']:2d}  n/a {c['n/a']:2d}")
    return 0


def cmd_next(args):
    secs, state, items, logs = parse_wb()
    open_items = [i for i in items if not i["done"]]
    print("Next checklist items:")
    for i in open_items[:5]:
        print(f"  {i['id']} {i['text']}   [{i['group']}]")
    rows = read_csv()
    todo = [r for r in rows if r["status"] in ("in-progress", "todo", "blocked")]
    print("\nNext kernels (kernels.csv; lines of the CPU code in the base commit):")
    for r in todo[:8]:
        print(f"  {r['status']:11s} {r['key']:14s} route={r['route'] or '-':24s} {r['base_refs'][:90]}")
    return 0


def cmd_set(args):
    rows = read_csv()
    sel = []
    if args.key.startswith("route:"):
        sel = [r for r in rows if r["route"] == args.key[6:]]
    else:
        sel = [r for r in rows if r["key"] == args.key]
        if not sel:
            sel = [r for r in rows if re.search(r"(^|[ ,/])" + re.escape(args.key) + r"($|[ ,/])", r["kernels"])]
    if not sel:
        print(f"no kernels.csv row matches {args.key}")
        return 1
    if args.status not in STATES:
        print(f"status must be one of {STATES}")
        return 1
    if args.status == "done" and not (args.commit and args.tests):
        print("'done' needs --commit and --tests")
        return 1
    if args.commit and not commit_exists(args.commit):
        print(f"commit {args.commit} does not exist")
        return 1
    for r in sel:
        r["status"] = args.status
        if args.commit:
            r["commit"] = args.commit
        if args.tests:
            r["tests"] = args.tests
        if args.note:
            r["notes"] = args.note
        print(f"{r['key']}: {args.status}")
    write_csv(rows)
    return 0


def cmd_check(args):
    bad = []
    if not os.path.exists(WB):
        print("FAIL  port/agent/WORKBOOK.md is missing")
        return 1
    secs, state, items, logs = parse_wb()
    for s in ("Current state", "Task checklist", "Log"):
        if s not in secs:
            bad.append(f"WORKBOOK.md has no '## {s}' section")
    for k in KEYS:
        if not state.get(k):
            bad.append(f"Current state: '- {k}: ...' is missing or empty")
    lc = state.get("Last commit", "")
    m = re.match(r"([0-9a-f]{7,40})\b", lc)
    if m and not commit_exists(m.group(1)):
        bad.append(f"Current state: Last commit {m.group(1)} does not exist")
    for it in items:
        if not it["done"]:
            continue
        cm = re.search(r"commit\s+([0-9a-f]{7,40})", it["text"])
        tm = re.search(r"tests\s+(\S.*)", it["text"])
        if not cm or not commit_exists(cm.group(1)):
            bad.append(f"checklist {it['id']}: ticked but names no existing commit ('— commit <sha> — tests ...')")
        if not tm:
            bad.append(f"checklist {it['id']}: ticked but names no tests")
        if not any(re.search(r"(^|\s)" + re.escape(it["id"]) + r"(\s|$|:)", h) for h in logs):
            bad.append(f"checklist {it['id']}: ticked but no '### <date> {it['id']} ...' log entry")
    rows = read_csv()
    keys = set()
    for r in rows:
        if r["key"] in keys:
            bad.append(f"kernels.csv: duplicate key {r['key']}")
        keys.add(r["key"])
        if r["status"] not in STATES:
            bad.append(f"kernels.csv {r['key']}: status '{r['status']}' not in {STATES}")
        if r["status"] == "done" and r["notes"] != "Phase 0":
            if not commit_exists(r["commit"]):
                bad.append(f"kernels.csv {r['key']}: done but commit '{r['commit']}' does not exist")
            if not r["tests"].strip():
                bad.append(f"kernels.csv {r['key']}: done but no tests")
        if r["status"] == "blocked" and not r["notes"].strip():
            bad.append(f"kernels.csv {r['key']}: blocked without a note (and a BLOCKERS.md entry)")
    base = open(os.path.join(AG, "cpu_view_base")).read().split("#")[0].split()[0]
    if base != ORIGINAL_BASE:
        ref = os.path.join(AG, "REFACTORS.md")
        if not os.path.exists(ref) or base[:12] not in open(ref).read():
            bad.append(f"cpu_view_base {base[:12]} is not the original base and is not listed in port/agent/REFACTORS.md")
    size = os.path.getsize(WB)
    if size > MAX_CHARS:
        bad.append(f"WORKBOOK.md has {size} characters (limit {MAX_CHARS}, context budget): "
                   f"run python3 port/tools/workbook.py archive")
    for head, body in log_entries(secs.get("Log", [])):
        while body and not body[-1].strip():
            body = body[:-1]
        if len(body) > MAX_ENTRY_LINES:
            bad.append(f"log entry '{head[4:60]}' has {len(body)} lines (limit {MAX_ENTRY_LINES}): shorten it")
    for b in bad:
        print("FAIL  " + b)
    done_k = sum(1 for r in rows if r["status"] == "done")
    print(f"workbook: {'PASS' if not bad else 'FAIL (' + str(len(bad)) + ')'}  "
          f"({sum(i['done'] for i in items)}/{len(items)} tasks, {done_k}/{len(rows)} kernel rows done)")
    return 1 if bad else 0


def cmd_resume(args):
    secs, state, items, logs = parse_wb()
    print("== Current state (port/agent/WORKBOOK.md)")
    for k in KEYS:
        print(f"  {k}: {state.get(k, '(missing)')}")
    print("\n== Next checklist items")
    for i in [i for i in items if not i["done"]][:3]:
        print(f"  {i['id']} {i['text'][:110]}   [{i['group'][:40]}]")
    rows = read_csv()
    prog = [r for r in rows if r["status"] == "in-progress"]
    todo = [r for r in rows if r["status"] == "todo"][:3]
    if prog or todo:
        print("\n== Kernels in progress, then next (show the CPU code: python3 port/tools/ref.py <key>)")
        for r in prog + todo:
            print(f"  {r['status']:11s} {r['key']:14s} {r['template']:3s} route={r['route']:24s} "
                  f"{r['base_refs'][:70]}{(' | ' + r['notes'][:60]) if r['notes'] else ''}")
    ents = log_entries(secs.get("Log", []))
    if ents:
        print("\n== Last log entries")
        for head, body in ents[-2:]:
            print(head)
            body = [x for x in body if x.strip()]
            for l in body[:15]:
                print(l)
            if len(body) > 15:
                print(f"  ... ({len(body) - 15} more lines in WORKBOOK.md)")
    bl = os.path.join(AG, "BLOCKERS.md")
    if os.path.exists(bl):
        open_b = [l.strip() for l in open(bl) if re.match(r"^## B\d+\b", l) and "resolved" not in l]
        print("\n== Open blockers: " + ("; ".join(open_b) if open_b else "none"))
    task = state.get("Current task", "").split()[0] if state.get("Current task") else ""
    if task:
        for card in sorted(f for f in os.listdir(AG) if re.match(r"PHASE\d\.md$", f)):
            lines = open(os.path.join(AG, card)).read().split("\n")
            hit = next((n for n, l in enumerate(lines) if l.startswith("#") and re.search(
                r"(^|[\s(])" + re.escape(task.split(".")[0] + "." + task.split(".")[1] if "." in task else task)
                + r"\b", l)), None)
            if hit is not None:
                lvl = len(lines[hit]) - len(lines[hit].lstrip("#"))
                end = next((n for n in range(hit + 1, len(lines)) if lines[n].startswith("#") and
                            len(lines[n]) - len(lines[n].lstrip("#")) <= lvl), len(lines))
                print(f"\n== Read the card section of {task}: sed -n '{hit + 1},{end}p' port/agent/{card}")
                break
    print("\n== Then: python3 port/tools/workbook.py next; the loop of port/agent/CHEATSHEET.md")
    return 0


def cmd_archive(args):
    text = open(WB).read()
    lines = text.split("\n")
    try:
        start = lines.index("## Log") + 1
    except ValueError:
        print("WORKBOOK.md has no '## Log' section")
        return 1
    end = next((n for n in range(start, len(lines)) if lines[n].startswith("## ")), len(lines))
    ents = log_entries(lines[start:end])
    if len(ents) <= args.keep:
        print(f"{len(ents)} log entries, nothing to archive (keep {args.keep})")
        return 0
    old, keep = ents[:-args.keep], ents[-args.keep:]
    first_entry = next(n for n in range(start, end) if lines[n].startswith("### "))
    new_log = [l for e in keep for l in [e[0]] + e[1]]
    lines[first_entry:end] = new_log
    open(WB, "w").write("\n".join(lines))
    head = "" if os.path.exists(ARCH) else ("# Workbook log archive\n\nOlder log entries of WORKBOOK.md, oldest "
                                              "first (moved by workbook.py archive).\n\n")
    with open(ARCH, "a") as f:
        f.write(head + "\n".join(l for e in old for l in [e[0]] + e[1]).rstrip("\n") + "\n\n")
    print(f"archived {len(old)} log entries to {os.path.relpath(ARCH, REPO)}; {len(keep)} kept")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status")
    p.add_argument("--phase")
    sub.add_parser("next")
    p = sub.add_parser("set")
    p.add_argument("key")
    p.add_argument("status")
    p.add_argument("--commit")
    p.add_argument("--tests")
    p.add_argument("--note")
    sub.add_parser("check")
    sub.add_parser("resume")
    p = sub.add_parser("archive")
    p.add_argument("--keep", type=int, default=10)
    args = ap.parse_args()
    return {"status": cmd_status, "next": cmd_next, "set": cmd_set, "check": cmd_check, "resume": cmd_resume,
            "archive": cmd_archive}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
