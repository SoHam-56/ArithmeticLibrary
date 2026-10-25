#!/usr/bin/env python3
"""4-state safe reading of what a simulation prints: a 4-state simulator (VCS) writes an unknown bit as x or z in a %h or %d field, which a plain
int() parse crashes on. Every reader of an output word, a cycle count or a hash goes through these, which raise Unknown with the FAIL line
('X in output word 37 of test <name>') instead; Unknown is a ValueError, so a reader that already fails a test on ValueError keeps doing so.
--selftest checks them."""

import re
import sys

XZ = re.compile(r"[xXzZ]")
HEX = r"[0-9a-fA-FxXzZ]+"  # a %h field as a 4-state simulator prints it
DEC = r"[0-9xXzZ]+"  # a %d field: x or X (some bits unknown), z or Z


class Unknown(ValueError):
    """An x or z where a number must be; str() is the FAIL line's text."""


def _bad(tok, what, index, test):
    c = "X" if re.search(r"[xX]", tok) else "Z"
    at = f" {index}" if index is not None else ""
    return Unknown(f"{c} in {what}{at} of test {test}" + (f" ({tok!r})" if len(tok) <= 40 else ""))


def word(tok, test, index=None, what="output word", base=16):
    """int(tok, base), or Unknown naming the word when tok holds an x or z bit."""
    tok = tok.strip()
    if XZ.search(tok):
        raise _bad(tok, what, index, test)
    return int(tok, base)


def words(tokens, test, what="output word", base=16, start=0):
    """[word(t)] of each token, numbered from start; the first x or z raises Unknown with its number."""
    return [word(t, test, i, what, base) for i, t in enumerate(tokens, start)]


def field(pattern, text, test, what, base=10, group=1, flags=0):
    """The int of re.search(pattern, text).group(group), None without a match; Unknown when it holds an x or z. Write the group as fourstate.DEC
    or fourstate.HEX so an unknown value still matches."""
    m = re.search(pattern, text, flags)
    return None if m is None else word(m.group(group), test, None, what, base)


def fields(pattern, text, test, what, base=10, flags=0):
    """Every match's groups as ints (a tuple per match); Unknown at the first x or z, named by what and the match's number."""
    out = []
    for k, m in enumerate(re.finditer(pattern, text, flags)):
        out.append(tuple(word(g, test, k, what, base) for g in m.groups()))
    return out


def column(rows, k, test, base=16, what="output word"):
    """np.int64 array of column k of a dump's split rows, the row number naming an x or z."""
    import numpy as np
    return np.array([word(r[k], test, i, what, base) for i, r in enumerate(rows)], dtype=np.int64)


def fail_line(e):
    """The plain FAIL line of an Unknown, as every parser prints it (regress.py's verdict looks for it)."""
    return f"FAIL: {e}"


LINE = re.compile(r"^.*\bFAIL: [XZ] in .*$", re.M)  # the line a verdict fails on


def selftest():
    n = 0

    def check(c, what):
        nonlocal n
        n += 1
        assert c, what

    def raises(f, want):
        try:
            f()
        except Unknown as e:
            check(str(e).startswith(want), (str(e), want))
            check(isinstance(e, ValueError), "Unknown must be a ValueError")
            return
        check(False, f"no Unknown, wanted {want}")
    check(word("3f", "t") == 63 and word(" 7FFF\n", "t") == 32767 and word("12", "t", base=10) == 12, "plain words")
    raises(lambda: word("xxxxxxxx", "mm_relu", 37), "X in output word 37 of test mm_relu")
    raises(lambda: word("3Xab", "t", 2), "X in output word 2 of test t")
    raises(lambda: word("zzzz", "t", 0), "Z in output word 0 of test t")
    raises(lambda: word("x", "t", None, "cycle count", 10), "X in cycle count of test t")
    check(words("1 2 a".split(), "t") == [1, 2, 10], "words")
    raises(lambda: words("1 2 x 4".split(), "t", start=35), "X in output word 37 of test t")
    check(field(rf"cycles=({DEC})", "sets=2 cycles=118 x", "t", "cycle count") == 118, "field")
    check(field(rf"cycles=({DEC})", "no such line", "t", "cycle count") is None, "field: no match")
    raises(lambda: field(rf"cycles=({DEC})", "sets=2 cycles=x", "t", "cycle count"), "X in cycle count of test t")
    raises(lambda: field(rf"HASH ({HEX})", "HASH 00ab0X00", "t", "word hash", 16), "X in word hash of test t")
    check(fields(rf"Set (\d+) : ({DEC}) cycles", "Set 0 : 12 cycles\nSet 1 : 14 cycles", "t", "cycle count") == [(0, 12), (1, 14)], "fields")
    raises(lambda: fields(rf"Set (\d+) : ({DEC}) cycles", "Set 0 : 12 cycles\nSet 1 : X cycles", "t", "cycle count"), "X in cycle count 1 of test t")
    try:
        word("xx", "t", 3)
    except ValueError as e:
        check(LINE.search(fail_line(e)) and fail_line(e) == "FAIL: X in output word 3 of test t ('xx')", fail_line(e))
    check(not LINE.search("exact 3 X in total\nFAIL: 3 of 9 words\n"), "only the X line matches")
    rows = [ln.split() for ln in "0a 01\n0b x1\n".splitlines()]
    check(list(column(rows, 0, "t")) == [10, 11], "column")
    raises(lambda: column(rows, 1, "dump.txt"), "X in output word 1 of test dump.txt")
    print(f"fourstate selftest: {n} checks, 0 failures")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        try:
            selftest()
        except AssertionError as e:
            print(f"fourstate selftest: FAIL {e}")
            sys.exit(1)
        print("RESULT: PASSED")
