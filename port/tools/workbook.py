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

check verifies:
  - WORKBOOK.md has the sections and the "Current state" keys, and its
    "Last commit" exists in git
  - every ticked checklist item names an existing commit and its tests, and has
    a log entry whose heading contains its ID
  - kernels.csv statuses are valid; every 'done' row has an existing commit and
    tests; every 'blocked' row has a note
  - the CPU-view base is the original one or is listed in port/agent/REFACTORS.md
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
    return secs, state, items, logs


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
    for b in bad:
        print("FAIL  " + b)
    done_k = sum(1 for r in rows if r["status"] == "done")
    print(f"workbook: {'PASS' if not bad else 'FAIL (' + str(len(bad)) + ')'}  "
          f"({sum(i['done'] for i in items)}/{len(items)} tasks, {done_k}/{len(rows)} kernel rows done)")
    return 1 if bad else 0


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
    args = ap.parse_args()
    return {"status": cmd_status, "next": cmd_next, "set": cmd_set, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
