#!/usr/bin/env python3
"""Extracts localizable string keys from the Swift sources.

Prints one key per line (format specifiers already substituted), or with --check <file.strings>
lists keys missing from the given strings file and exits non-zero if any are missing.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Sources"

INT_HINTS = re.compile(r"(count|Count|index|seconds|minutes|hours|attempts|chapters|lastNewCount|totalDownloaded|"
                       r"maxConcurrent|autoRetry|concurrentFragments|trimFilenames|^Int\(|^i$|^n$|^delay|"
                       r"activeCount|finishedCount|pendingCount|Int\(delay\)|minutes / 60|minutes % 60|index \+ 1|^active$|^waiting$|"
                       r"^failed$|^added$|^changed$|^failures$|skippedItems|^done$|^code$|musicAttempt)")

CALLS = [
    r'Text\(', r'Label\(', r'Button\(', r'Toggle\(', r'Picker\(', r'Section\(', r'\.help\(', r'TextField\(',
    r'Stepper\(', r'LabeledContent\(', r'ContentUnavailableView\(', r'String\(localized:\s*', r'LocalizedStringKey\(',
    r'Menu\(', r'CommandMenu\(', r'\.confirmationDialog\(', r'title:\s*', r'subtitle:\s*', r'return\s+',
    r'SettingsLink\s*\{\s*Text\(', r'\.badge\(', r'feature\("[^"]*",\s*', r'iconButton\("[^"]*",\s*help:\s*',
    r'\(\s*"[^"]*",\s*', r'\?\s*', r':\s*', r'",\s*',
]


def swift_string_literals(src):
    """Yields (start_index, raw_literal_content) for every plain "..." literal (handles \\( ) nesting)."""
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '#' and src.startswith('#"', i):
            j = src.find('"#', i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            j = i + 1
            depth = 0
            buf = []
            while j < n:
                ch = src[j]
                if ch == '\\' and j + 1 < n:
                    if src[j + 1] == '(':
                        depth += 1
                        buf.append('\\(')
                        j += 2
                        continue
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if depth > 0:
                    if ch == '(':
                        depth += 1
                    elif ch == ')':
                        depth -= 1
                    buf.append(ch)
                    j += 1
                    continue
                if ch == '"':
                    break
                if ch == '\n':
                    break
                buf.append(ch)
                j += 1
            yield i, ''.join(buf)
            i = j + 1
            continue
        i += 1


def to_key(literal):
    out = []
    i = 0
    while i < len(literal):
        if literal.startswith('\\(', i):
            depth = 1
            j = i + 2
            while j < len(literal) and depth:
                if literal[j] == '(':
                    depth += 1
                elif literal[j] == ')':
                    depth -= 1
                j += 1
            expr = literal[i + 2:j - 1].strip()
            is_int = INT_HINTS.search(expr) and not expr.startswith(('Format.', 'String(', 'URLTools.'))
            out.append('%lld' if is_int else '%@')
            i = j
            continue
        if literal[i] == '%':
            out.append('%%')
            i += 1
            continue
        out.append(literal[i])
        i += 1
    return ''.join(out).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')


CONTEXT = re.compile(r'(' + '|'.join(CALLS) + r')$')
SKIP = re.compile(r'^(%[@a-z]*|[\W\d_]*|[a-z0-9_.\-]+|https?:.*|[A-Z0-9]{2,5}|.*\.(png|json|log|txt)|yt-dlp( %@)?|MYTDL.*|javascript:.*)$')


def extract():
    keys = []
    for path in sorted(ROOT.rglob('*.swift')):
        src = path.read_text()
        for start, literal in swift_string_literals(src):
            before = src[max(0, start - 60):start]
            if not CONTEXT.search(before):
                continue
            # Ignore string literals that are clearly not UI text.
            key = to_key(literal)
            if SKIP.match(key) or len(key) < 2:
                continue
            if any(x in key for x in ('%(', 'Lasso.reset', 'com.apple', '/usr/', 'showSettingsWindow')):
                continue
            if key not in keys:
                keys.append(key)
    return keys


def parse_strings(path):
    text = Path(path).read_text()
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))


if __name__ == '__main__':
    keys = extract()
    if len(sys.argv) > 2 and sys.argv[1] == '--check':
        existing = {k.replace('\\"', '"').replace('\\n', '\n') for k in parse_strings(sys.argv[2])}
        missing = [k for k in keys if k not in existing]
        for k in missing:
            print('MISSING:', repr(k))
        sys.exit(1 if missing else 0)
    for k in keys:
        print(repr(k))
