#!/usr/bin/env python3
"""Rewrite transcendental intrinsics and real powers to module_repro_math calls
(plan.md P0.6).

For each free-form Fortran file given:

  EXP LOG LOG10 SIN COS TAN ASIN ACOS ATAN ATAN2 SINH COSH TANH MOD and their
  specific names (ALOG, ALOG10, AMOD, DEXP, DLOG, DSIN, ...)  ->  rp_exp(...), ...
  a**b where b is not an integer literal                      ->  rp_pow(a, b)

and adds "USE module_repro_math" to every program unit it changes.

Operands of ** are parsed on Fortran tokens (primaries: literals, names with
component and argument lists, parenthesized expressions), so precedence is
kept: -a**b becomes -rp_pow(a,b), a**b**c becomes rp_pow(a, rp_pow(b,c)).
Integer-literal exponents (x**2, x**3) are left alone; they are checked by
T-IPOW.  A non-literal exponent is always wrapped: the generic rp_pow resolves
INTEGER exponents to x**n unchanged.

Not rewritten, and reported:
  - type declaration, PARAMETER, DATA, FORMAT, INTRINSIC and EXTERNAL
    statements (their expressions must stay constant expressions)
  - a ** whose operand continues on another line  -> "manual"
  - other transcendental intrinsics (ERF, GAMMA, HYPOT, ASINH, ...)  -> "refused"
  - fixed-form files                               -> "refused"

Usage:
  rp_subst.py [--check] [--log FILE] file ...     rewrite (or only report)
  rp_subst.py --scan dir ...                      list files that call any of
                                                  the functions or use real powers
"""

import argparse
import os
import re
import sys

FUNC_MAP = {
    "exp": "rp_exp", "dexp": "rp_exp",
    "log": "rp_log", "alog": "rp_log", "dlog": "rp_log",
    "log10": "rp_log10", "alog10": "rp_log10", "dlog10": "rp_log10",
    "sin": "rp_sin", "dsin": "rp_sin",
    "cos": "rp_cos", "dcos": "rp_cos",
    "tan": "rp_tan", "dtan": "rp_tan",
    "asin": "rp_asin", "dasin": "rp_asin",
    "acos": "rp_acos", "dacos": "rp_acos",
    "atan": "rp_atan", "datan": "rp_atan",
    "atan2": "rp_atan2", "datan2": "rp_atan2",
    "sinh": "rp_sinh", "dsinh": "rp_sinh",
    "cosh": "rp_cosh", "dcosh": "rp_cosh",
    "tanh": "rp_tanh", "dtanh": "rp_tanh",
    "mod": "rp_mod", "amod": "rp_mod", "dmod": "rp_mod",
}
REFUSED = {"erf", "erfc", "derf", "derfc", "gamma", "dgamma", "lgamma", "log_gamma", "hypot",
           "asinh", "acosh", "atanh", "bessel_j0", "bessel_j1", "bessel_jn", "bessel_y0",
           "bessel_y1", "bessel_yn", "cexp", "clog", "csin", "ccos", "erfc_scaled", "expm1",
           "log1p", "cbrt"}

DECL_START = re.compile(
    r"^\s*(real|integer|logical|complex|character|double\s*precision|double\s*complex|type\s*\(|class\s*\(|"
    r"byte)\b(?!\s*function\b)", re.I)
DECL_FUNCTION = re.compile(r"^\s*(real|integer|logical|complex|character|double\s*precision)"
                           r"(\s*\*\s*\d+|\s*\([^)]*\))?\s*(elemental\s+|pure\s+|recursive\s+)*function\b", re.I)
SKIP_START = re.compile(r"^\s*(\d+\s+)?(parameter|data|format|intrinsic|external|implicit|save|common|"
                        r"equivalence|namelist|dimension|allocatable|public|private|use|include)\b", re.I)
UNIT_START = re.compile(
    r"^\s*((pure|elemental|recursive|impure|module)\s+)*"
    r"((real|integer|logical|complex|character|double\s*precision)(\s*\*\s*\d+|\s*\([^)]*\))?\s+)?"
    r"((pure|elemental|recursive)\s+)*"
    r"(subroutine|function|program|module)\s+(\w+)", re.I)
MODULE_PROC = re.compile(r"^\s*module\s+procedure\b", re.I)
USE_LINE = re.compile(r"^   USE module_repro_math\s*$")
RP_CALL = re.compile(r"\brp_(exp|log|log10|pow|sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|mod)\s*\(", re.I)

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<str>'(?:[^']|'')*'|"(?:[^"]|"")*")
  | (?P<num>(?:\d+(?:\.(?![a-zA-Z]+\.)\d*)?|\.\d+)(?:[eEdD][+-]?\d+)?(?:_\w+)?)
  | (?P<dop>\.(?:and|or|not|eqv|neqv|eq|ne|lt|le|gt|ge|true|false)\.(?:_\w+)?)
  | (?P<name>[A-Za-z_]\w*)
  | (?P<op>\*\*|//|==|/=|<=|>=|=>|::|[-+*/=<>(),%:;&\[\]])
  | (?P<other>.)
""", re.X | re.I)


class Tok:
    __slots__ = ("kind", "text", "start", "end")

    def __init__(self, kind, text, start, end):
        self.kind, self.text, self.start, self.end = kind, text, start, end


def tokenize(code):
    toks = []
    for m in TOKEN_RE.finditer(code):
        k = m.lastgroup
        if k == "ws":
            continue
        toks.append(Tok(k, m.group(0), m.start(), m.end()))
    return toks


def split_comment(line):
    """Return (code, comment) for a free-form line, respecting strings."""
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
            continue
        if ch in "'\"":
            q = ch
        elif ch == "!":
            return line[:i], line[i:]
    return line, ""


def is_int_literal(text):
    return re.fullmatch(r"[+-]?\d+(_\w+)?", text) is not None


class NeedManual(Exception):
    pass


def match_paren_fwd(toks, i):
    """toks[i] is '(' or '['; return index of the matching close."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j].text
        if t in "([":
            depth += 1
        elif t in ")]":
            depth -= 1
            if depth == 0:
                return j
    raise NeedManual("unbalanced parenthesis (continued line)")


def match_paren_back(toks, i):
    """toks[i] is ')' or ']'; return index of the matching open."""
    depth = 0
    for j in range(i, -1, -1):
        t = toks[j].text
        if t in ")]":
            depth += 1
        elif t in "([":
            depth -= 1
            if depth == 0:
                return j
    raise NeedManual("unbalanced parenthesis (continued line)")


def primary_right(toks, i):
    """Primary starting at toks[i] (after '**'); returns index of its last token."""
    if i >= len(toks) or toks[i].text == "&":
        raise NeedManual("exponent continues on the next line")
    j = i
    if toks[j].text in "+-":
        j += 1
        if j >= len(toks) or toks[j].text == "&":
            raise NeedManual("exponent continues on the next line")
    t = toks[j]
    if t.kind == "num":
        return j
    if t.text == "(":
        return match_paren_fwd(toks, j)
    if t.kind == "name":
        k = j
        while True:
            if k + 1 < len(toks) and toks[k + 1].text == "(":
                k = match_paren_fwd(toks, k + 1)
                continue
            if k + 2 < len(toks) and toks[k + 1].text == "%" and toks[k + 2].kind == "name":
                k += 2
                continue
            break
        return k
    raise NeedManual(f"unexpected exponent token {t.text!r}")


def primary_left(toks, i):
    """Primary ending at toks[i] (before '**'); returns index of its first token."""
    if i < 0:
        raise NeedManual("base starts on the previous line")
    t = toks[i]
    if t.text == "&":
        raise NeedManual("base starts on the previous line")
    if t.kind == "num":
        return i
    if t.text in ")]":
        j = match_paren_back(toks, i)
        if j - 1 >= 0 and toks[j - 1].kind == "name":
            j -= 1
        elif j - 1 >= 0 and toks[j - 1].text == ")":
            # e.g. a(i)(1:2): substring of an array element
            return primary_left(toks, j - 1)
        return extend_component_left(toks, j)
    if t.kind == "name":
        return extend_component_left(toks, i)
    raise NeedManual(f"unexpected base token {t.text!r}")


def extend_component_left(toks, j):
    # include "x(..)%" or "x%" before a component name
    while j - 2 >= 0 and toks[j - 1].text == "%":
        k = j - 2
        if toks[k].text == ")":
            k = match_paren_back(toks, k)
            if k - 1 >= 0 and toks[k - 1].kind == "name":
                k -= 1
            else:
                break
        elif toks[k].kind != "name":
            break
        j = k
    return j


def rewrite_powers(code, report):
    """Rewrite a**b in one line of code (no comment).  Returns new code."""
    # Stars are processed right to left; a star's distance from the end of the
    # line does not change when a star to its left is rewritten.
    changed = True
    done = set()
    while changed:
        changed = False
        toks = tokenize(code)
        stars = [i for i, t in enumerate(toks) if t.text == "**"]
        for si in reversed(stars):
            key = len(code) - toks[si].start
            if key in done:
                continue
            try:
                r_end = primary_right(toks, si + 1)
            except NeedManual as e:
                report("manual", str(e))
                done.add(key)
                continue
            exp_text = code[toks[si + 1].start:toks[r_end].end]
            if is_int_literal(exp_text.replace(" ", "")):
                done.add(key)
                continue
            try:
                l_start = primary_left(toks, si - 1)
            except NeedManual as e:
                report("manual", str(e))
                done.add(key)
                continue
            base_text = code[toks[l_start].start:toks[si - 1].end]
            new = f"rp_pow({base_text}, {exp_text})"
            code = code[:toks[l_start].start] + new + code[toks[r_end].end:]
            report("pow", new)
            changed = True
            break
    return code


def rewrite_calls(code, report):
    toks = tokenize(code)
    out = code
    # right to left so offsets stay valid
    for i in range(len(toks) - 1, -1, -1):
        t = toks[i]
        if t.kind != "name" or i + 1 >= len(toks) or toks[i + 1].text != "(":
            continue
        if i > 0 and toks[i - 1].text == "%":
            continue
        low = t.text.lower()
        if low in FUNC_MAP:
            out = out[:t.start] + FUNC_MAP[low] + out[t.end:]
            report("call", f"{t.text} -> {FUNC_MAP[low]}")
        elif low in REFUSED:
            report("refused", f"{t.text}(")
    return out


def is_fixed_form(lines):
    """Fixed form if it has column-1 comment lines and no '&' continuations.
    (WRF's frame/libmassv.F uses only the subset common to both forms and is
    compiled as free form, so it counts as free form here.)"""
    comment_c = sum(1 for l in lines if re.match(r"^[cC*](\s|$)", l))
    amp = sum(1 for l in lines if split_comment(l)[0].rstrip().endswith("&"))
    return comment_c >= 3 and amp == 0


def statements(lines):
    """Group free-form physical lines into statements: yields lists of the
    indices of the code lines of each statement.  Comment-only, blank and
    preprocessor lines inside a continued statement (e.g. a SUBROUTINE header
    continued through an #include of its argument list) do not end it."""
    cur = []
    for idx, line in enumerate(lines):
        s = line.strip()
        code, _ = split_comment(line)
        if s.startswith("#") or not code.strip():
            if not cur:
                yield [idx]
            continue
        cur.append(idx)
        if code.rstrip().endswith("&"):
            continue
        yield cur
        cur = []
    if cur:
        yield cur


def classify(stmt_text):
    t = stmt_text.strip()
    t = re.sub(r"^\d+\s+", "", t)       # statement label
    if not t or t.startswith("#"):
        return "skip"
    if MODULE_PROC.match(t):
        return "skip"
    if DECL_FUNCTION.match(t):
        return "unit"
    if UNIT_START.match(t) and not re.match(r"^\s*module\s+procedure", t, re.I):
        return "unit"
    if DECL_START.match(t):
        return "decl"
    if SKIP_START.match(t):
        return "skip"
    if re.match(r"^\s*end\b", t, re.I):
        return "end"
    if re.match(r"^\s*contains\b", t, re.I):
        return "contains"
    return "exec"


def process_file(path, check_only, log):
    with open(path, errors="replace") as f:
        lines = f.read().split("\n")
    original = list(lines)
    stats = {"call": 0, "pow": 0, "manual": 0, "refused": 0}
    if is_fixed_form(lines) and not path.endswith((".f90", ".F90")):
        log(f"{path}: refused: fixed-form source, edit by hand")
        stats["refused"] += 1
        return stats, False

    # Our own USE lines are removed and re-inserted below, so running the
    # script again on a rewritten file is safe.
    lines = [l for l in lines if not USE_LINE.match(l)]
    new_lines = list(lines)
    # program units: remember header statements and whether the unit uses rp_*
    units = []            # [header_last_line_idx, changed, name, depth]
    stack = []
    # Program-unit structure across cpp conditionals: every #else/#elif
    # branch starts from the unit stack as it was at the #if, so each branch
    # is followed on its own.  (module_fr_fire_core.F has one function header
    # and an END in each branch; module_diag_misc.F has a stub module in the
    # #if branch and the real module in the #else branch.)
    cpp = []              # per #if level: copy of the unit stack at the #if
    for stmt in statements(lines):
        first = lines[stmt[0]].strip()
        if first.startswith("#"):
            d = first[1:].strip()
            if d.startswith("if"):
                cpp.append(list(stack))
            elif d.startswith(("else", "elif")) and cpp:
                stack[:] = list(cpp[-1])
            elif d.startswith("endif") and cpp:
                cpp.pop()
            continue
        text = " ".join(split_comment(lines[i])[0].rstrip().rstrip("&") for i in stmt)
        kind = classify(text)
        if kind == "unit":
            m = UNIT_START.match(re.sub(r"^\s*\d+\s+", "", text)) or DECL_FUNCTION.match(text)
            name = m.group(0).split()[-1] if m else "?"
            unit = [stmt[-1], False, name, len(stack)]
            units.append(unit)
            stack.append(unit)
            continue
        if kind == "end":
            if re.match(r"^\s*end\s*(subroutine|function|program|module)?\s*\w*\s*$", text, re.I) and \
                    not re.match(r"^\s*end\s*(if|do|select|where|forall|type|interface|associate|block)", text, re.I):
                if stack:
                    stack.pop()
            continue
        if kind != "exec":
            continue
        for i in stmt:
            code, comment = split_comment(new_lines[i])

            def rep(kind_, msg, _i=i):
                stats[kind_] += 1
                if kind_ in ("manual", "refused"):
                    log(f"{path}:{_i + 1}: {kind_}: {msg}")
                    log(f"    {lines[_i].strip()}")
            c2 = rewrite_powers(code, rep)
            c2 = rewrite_calls(c2, rep)
            if c2 != code:
                new_lines[i] = c2 + comment
                log(f"{path}:{i + 1}:")
                log(f"  - {lines[i].strip()}")
                log(f"  + {new_lines[i].strip()}")
            # mark the outermost enclosing unit (module or external procedure)
            if stack and RP_CALL.search(c2):
                stack[0][1] = True
    # insert USE after the header of each outermost unit that calls rp_*
    inserts = sorted((u[0] for u in units if u[1] and u[3] == 0), reverse=True)
    for idx in inserts:
        new_lines.insert(idx + 1, "   USE module_repro_math")
    changed = new_lines != original
    if changed and not check_only:
        with open(path, "w") as f:
            f.write("\n".join(new_lines))
    return stats, changed


def scan(dirs):
    pat_call = re.compile(r"\b(" + "|".join(sorted(FUNC_MAP, key=len, reverse=True)) + r")\s*\(", re.I)
    pat_pow = re.compile(r"\*\*\s*[-+]?\s*(\d*\.\d*|[A-Za-z_(])")
    for d in dirs:
        for root, _, files in os.walk(d):
            for fn in sorted(files):
                if not fn.endswith((".F", ".F90", ".f90")):
                    continue
                p = os.path.join(root, fn)
                nc = npw = 0
                with open(p, errors="replace") as f:
                    for line in f:
                        code, _ = split_comment(line)
                        if code.lstrip().startswith("#"):
                            continue
                        nc += len(pat_call.findall(code))
                        npw += len(pat_pow.findall(code))
                if nc or npw:
                    print(f"{nc:6d} calls {npw:6d} powers  {p}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--check", action="store_true", help="report only, do not modify files")
    ap.add_argument("--scan", action="store_true", help="list files that use the functions")
    ap.add_argument("--log", help="write the full rewrite log to this file")
    args = ap.parse_args()
    if args.scan:
        scan(args.files)
        return 0
    logf = open(args.log, "w") if args.log else None

    def log(msg):
        if logf:
            logf.write(msg + "\n")
        if "manual" in msg or "refused" in msg:
            print(msg)

    total = {"call": 0, "pow": 0, "manual": 0, "refused": 0}
    for p in args.files:
        st, ch = process_file(p, args.check, log)
        for k in total:
            total[k] += st[k]
        print(f"{p}: {st['call']} calls, {st['pow']} powers, {st['manual']} manual, {st['refused']} refused"
              f"{'' if ch else ' (unchanged)'}")
    print(f"total: {total['call']} calls, {total['pow']} powers, {total['manual']} manual, "
          f"{total['refused']} refused")
    if logf:
        logf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
