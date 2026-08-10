#!/usr/bin/env python3
"""Validate relative markdown links and anchors in README.md and doc/*.md."""
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def github_anchor(heading: str) -> str:
    text = heading.strip().lower()
    # remove markdown formatting chars
    text = re.sub(r"[`*_]", "", text)
    out = []
    for ch in text:
        if ch in (" ", "-"):
            out.append("-" if ch == " " else ch)
        elif ch.isalnum() or ch == "_":
            out.append(ch)
        elif unicodedata.category(ch).startswith("L") or unicodedata.category(ch).startswith("N"):
            out.append(ch)
        # everything else (punctuation) is dropped
    return "".join(out)


def collect_anchors(path):
    anchors = set()
    in_fence = False
    with open(path) as f:
        for line in f:
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = re.match(r"^(#{1,6})\s+(.*)", line)
            if m:
                anchors.add(github_anchor(m.group(2)))
    return anchors


link_re = re.compile(r"\]\(([^)\s]+)\)")
failures = []
checked = 0

files = ["README.md"] + sorted(
    os.path.join("doc", f) for f in os.listdir(os.path.join(ROOT, "doc")) if f.endswith(".md")
)

for rel in files:
    path = os.path.join(ROOT, rel)
    with open(path) as f:
        content = f.read()
    for target in link_re.findall(content):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        checked += 1
        if "#" in target:
            file_part, anchor = target.split("#", 1)
        else:
            file_part, anchor = target, None
        if file_part:
            dest = os.path.normpath(os.path.join(os.path.dirname(rel), file_part))
            if not os.path.exists(os.path.join(ROOT, dest)):
                failures.append(f"{rel}: missing file target '{target}'")
                continue
        else:
            dest = rel
        if anchor:
            anchors = collect_anchors(os.path.join(ROOT, dest))
            if anchor not in anchors:
                failures.append(f"{rel}: anchor '#{anchor}' not found in {dest} (have: {sorted(a for a in anchors if a.startswith(anchor[:6]))}...)")

print(f"checked {checked} relative links across {len(files)} files")
if failures:
    print(f"\n{len(failures)} FAILURES:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("all links OK")
