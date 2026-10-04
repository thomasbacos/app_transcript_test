"""
Lists the user-facing strings of the iOS app: the keys Localizable.xcstrings must contain.

    python scripts/extract_strings.py             # every key, with the file it comes from
    python scripts/build_strings.py               # regenerate the .xcstrings catalogs (EN + FR)

Interpolated SwiftUI literals (Text("\\(x) min")) are reported on stderr: use tr("%lld min", x) instead,
so the key is explicit.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios")
STR = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [r'\btr\(\s*' + STR, r'\bText\(\s*' + STR, r'\bButton\(\s*' + STR, r'\bLabel\(\s*' + STR,
            r'\bToggle\(\s*' + STR, r'\bSection\(\s*' + STR, r'\bPicker\(\s*' + STR, r'\bTextField\(\s*' + STR,
            r'\.navigationTitle\(\s*' + STR, r'\.alert\(\s*' + STR, r'\.confirmationDialog\(\s*' + STR,
            r'\bContentUnavailableView\(\s*' + STR, r'\bLocalizedStringKey\(\s*' + STR,
            r'LocalizedStringResource\s*=\s*' + STR, r'\bIntentDescription\(\s*' + STR, r'shortTitle:\s*' + STR]


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def scan(folder):
    keys = {}
    for dp, _, files in os.walk(folder):
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            src = open(os.path.join(dp, f), encoding="utf-8").read()
            for pat in PATTERNS:
                for m in re.finditer(pat, src):
                    k = m.group(1)
                    if "\\(" in k:
                        print("INTERPOLATED (use tr):", f, k, file=sys.stderr)
                        continue
                    keys.setdefault(unescape(k), f)
    return keys


def keys_for(targets):
    out = {}
    for t in targets:
        out.update(scan(os.path.join(ROOT, t)))
    return out


if __name__ == "__main__":
    for k, f in sorted(keys_for(sys.argv[1:] or ["Parley", "Shared"]).items()):
        print("%s\t%s" % (f, k))
