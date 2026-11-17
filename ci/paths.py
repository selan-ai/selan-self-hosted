"""Path coverage of install.sh across the cases: every command line ran in some case, and every `fail`
ran as a `fail`, so a refusal that is never taken shows up even when its condition's line ran.

  python3 ci/paths.py ci-out/paths-*.txt

Each input holds "<line> <command>" pairs that ci/dind-test.sh kept from install.sh's xtrace. A line no
case can reach on a CI runner is listed in ci/paths-allowed.txt as "<text of the line> | <why>".
"""
import pathlib
import re
import sys

SOURCE = pathlib.Path(__file__).resolve().parent.parent / "install.sh"
ALLOWED = pathlib.Path(__file__).resolve().parent / "paths-allowed.txt"
STRUCTURE = re.compile(r"^(\}|fi|done( .*)?|esac|;;|then|else|do|\{|\(|\)|\} >.*|[A-Za-z_0-9]+\(\) \{|(\*|[a-z|]+)\))$")
CONTINUES = re.compile(r"(\\|\||&&|\|\||\{)$")


def points():
    lines = SOURCE.read_text().splitlines()
    heredoc, previous = None, ""
    for number, raw in enumerate(lines, 1):
        text = raw.strip()
        if heredoc:
            heredoc = None if text == heredoc else heredoc
            continue
        marker = re.search(r"<<-?'?([A-Z]+)'?", text)
        if marker and not text.startswith("#"):
            heredoc = marker.group(1)
        continuation = bool(CONTINUES.search(previous)) and not previous.endswith("{")
        previous = text if text and not text.startswith("#") else previous
        if not text or text.startswith("#") or STRUCTURE.match(text) or text.startswith(("local ", "set -")):
            continue
        if number < 3:
            continue
        has_fail = re.search(r"(^|[|&;{] *)fail ", text) is not None
        if continuation and not has_fail:
            continue
        yield number, text, has_fail


def main(paths):
    ran = set()
    for path in paths:
        for row in pathlib.Path(path).read_text().splitlines():
            line, _, command = row.partition(" ")
            ran.add((int(line), command))
    lines_run = {line for line, _ in ran}
    allowed = {}
    for row in ALLOWED.read_text().splitlines() if ALLOWED.exists() else []:
        if row.strip() and not row.startswith("#"):
            text, _, why = row.partition(" | ")
            allowed[text.strip()] = why.strip()
    missed, total, excused = [], 0, []
    for number, text, has_fail in points():
        total += 1
        taken = (number, "fail") in ran if has_fail else number in lines_run
        if taken:
            continue
        if text in allowed:
            excused.append((number, text, allowed.pop(text)))
        else:
            missed.append((number, "fail never ran" if has_fail else "never ran", text))
    print(f"install.sh: {total - len(missed) - len(excused)} of {total} paths taken by a case, {len(excused)} excused")
    for number, text, why in excused:
        print(f"  excused {number}: {text}  ({why})")
    for number, kind, text in missed:
        print(f"  MISSED {number} ({kind}): {text}")
    for text in allowed:
        print(f"  STALE allowance, now taken or gone: {text}")
    return 1 if missed or allowed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
