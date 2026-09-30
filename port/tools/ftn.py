"""Small helpers for reading WRF's free-form Fortran (used by arith_guard.py and
kernel_lint.py).

- cpp_view(lines, gpu):   resolve only the GPU-port conditionals (#ifdef
  WRF_GPU, #ifdef WRF_TRACE_FINE, #ifndef WRF_GPU, ...) for
  the CPU view (gpu=False) or the GPU view (gpu=True).  Every other
  preprocessor line is kept unchanged with both of its branches, so two
  versions of a file can be compared line by line.
- statements(lines):      join '&' continuations, drop comments; yields
  (first_line_number, statement_text, is_directive).  Directive lines
  ('!$omp', '!$acc', '!dir$') are returned separately with is_directive=True.
- normalize(stmt):        lower case, blanks removed outside strings.
"""

import re

GPU_MACROS = {"WRF_GPU", "WRF_TRACE_FINE", "WRF_GPU_TRACE_FINE", "WRF_GPU_CAPTURE"}
DIRECTIVE = re.compile(r"^\s*!(\$omp|\$acc|dir\$)", re.I)
CPP = re.compile(r"^\s*#\s*(\w+)\s*(.*)$")


def _eval_cond(expr, gpu):
    """Three-valued evaluation of a cpp condition: True, False or None
    (depends on macros other than the GPU-port ones)."""
    e = expr.strip()
    toks = re.findall(r"defined\s*\(\s*\w+\s*\)|defined\s+\w+|&&|\|\||!|\(|\)|\w+|\S", e)
    vals = []
    for t in toks:
        m = re.match(r"defined\s*\(?\s*(\w+)", t)
        if m:
            name = m.group(1)
            vals.append(gpu if name in GPU_MACROS else None)
        elif t in ("&&", "||", "!", "(", ")"):
            vals.append(t)
        elif t in GPU_MACROS:
            vals.append(gpu)
        else:
            return None                     # comparisons, other macros: unknown

    pos = 0

    def primary():
        nonlocal pos
        t = vals[pos]
        if t == "!":
            pos += 1
            v = primary()
            return None if v is None else (not v)
        if t == "(":
            pos += 1
            v = disj()
            pos += 1                        # ')'
            return v
        pos += 1
        return t

    def conj():
        nonlocal pos
        v = primary()
        while pos < len(vals) and vals[pos] == "&&":
            pos += 1
            w = primary()
            v = False if (v is False or w is False) else (None if (v is None or w is None) else True)
        return v

    def disj():
        nonlocal pos
        v = conj()
        while pos < len(vals) and vals[pos] == "||":
            pos += 1
            w = conj()
            v = True if (v is True or w is True) else (None if (v is None or w is None) else False)
        return v

    try:
        return disj()
    except (IndexError, TypeError):
        return None


def cpp_view(lines, gpu):
    """Return [(line_number, text)] of the lines kept in the CPU or GPU view."""
    out = []
    stack = []          # entries: ('gpu', active_now, taken_any) or ('other',)
    def active():
        return all(s[1] for s in stack if s[0] == "gpu")
    for n, line in enumerate(lines, 1):
        m = CPP.match(line)
        if m:
            d, rest = m.group(1).lower(), m.group(2)
            if d in ("if", "ifdef", "ifndef"):
                cond = {"ifdef": f"defined({rest.split()[0] if rest.split() else ''})",
                        "ifndef": f"!defined({rest.split()[0] if rest.split() else ''})"}.get(d, rest)
                v = _eval_cond(cond, gpu)
                if v is None:
                    stack.append(("other",))
                    if active():
                        out.append((n, line))
                else:
                    stack.append(("gpu", v, v))
                continue
            if d in ("elif", "else"):
                if stack and stack[-1][0] == "gpu":
                    kind, cur, taken = stack[-1]
                    if d == "else":
                        stack[-1] = ("gpu", not taken, True)
                    else:
                        v = _eval_cond(rest, gpu)
                        v = bool(v) if v is not None else False
                        stack[-1] = ("gpu", (not taken) and v, taken or v)
                    continue
                if active():
                    out.append((n, line))
                continue
            if d == "endif":
                if stack:
                    top = stack.pop()
                    if top[0] == "gpu":
                        continue
                if active():
                    out.append((n, line))
                continue
        if active():
            out.append((n, line))
    return out


def strip_comment(line):
    """Code part of a free-form line (a '!' inside a string is not a comment)."""
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "!":
            return line[:i]
    return line


def statements(numbered_lines):
    """Join continuation lines of [(n, text)]; yield (n, stmt, is_directive).
    Preprocessor lines are yielded as their own statements."""
    buf = None
    start = 0
    dbuf = None
    dstart = 0
    for n, line in numbered_lines:
        if DIRECTIVE.match(line):
            text = re.sub(r"^\s*!\$(omp|acc)\s*&?", "", line, flags=re.I).rstrip()
            cont = text.rstrip().endswith("&")
            text = text.rstrip().rstrip("&")
            if dbuf is None:
                dbuf, dstart = line.strip().split(None, 1)[0] + " " + text, n
            else:
                dbuf += " " + text
            if not cont:
                yield dstart, dbuf, True
                dbuf = None
            continue
        if line.lstrip().startswith("#"):
            if buf is None:
                yield n, line.strip(), False
            continue
        code = strip_comment(line).rstrip()
        if not code.strip():
            continue
        cont = code.endswith("&")
        code = code[:-1] if cont else code
        code = re.sub(r"^\s*&", "", code)
        if buf is None:
            buf, start = code, n
        else:
            buf += " " + code
        if not cont:
            for part in split_semicolons(buf):
                yield start, part.strip(), False
            buf = None
    if buf:
        yield start, buf.strip(), False


def split_semicolons(stmt):
    parts, q, cur = [], None, ""
    for c in stmt:
        if q:
            cur += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            cur += c
        elif c == ";":
            parts.append(cur)
            cur = ""
        else:
            cur += c
    parts.append(cur)
    return [p for p in parts if p.strip()]


def normalize(stmt):
    """Lower case and remove blanks outside character strings."""
    out, q = [], None
    for c in stmt:
        if q:
            out.append(c)
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            out.append(c)
        elif not c.isspace():
            out.append(c.lower())
    return "".join(out)


TOKEN = re.compile(r"(\d+\.\d*(?:[ed][+-]?\d+)?(?:_\w+)?|\.\d+(?:[ed][+-]?\d+)?(?:_\w+)?|\d+(?:[ed][+-]?\d+)?(?:_\w+)?"
                   r"|\.(?:and|or|not|eq|ne|lt|le|gt|ge|true|false|eqv|neqv)\.|[a-z_]\w*|\*\*|//|==|/=|<=|>=|=>|'[^']*'|\"[^\"]*\"|\S)")


def tokens(norm_stmt):
    return TOKEN.findall(norm_stmt)
