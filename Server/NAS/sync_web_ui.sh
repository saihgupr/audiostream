#!/bin/bash
# Regenerates web/index.html from the single source of truth, the Swift
# multi-line string in ../Core/MusicServerHTML.swift. Both the iPhone daemon
# and this server serve the same player, so the HTML lives in one place and
# this copy is generated. `go test` fails if the two drift apart.
set -euo pipefail

cd "$(dirname "$0")"

python3 - <<'PY'
import pathlib
import re

src = pathlib.Path("../Core/MusicServerHTML.swift").read_text()
match = re.search(r'public static let content = """\n(.*?)\n"""', src, re.S)
if not match:
    raise SystemExit("could not find MusicServerHTML.content in the Swift source")

out = pathlib.Path("web/index.html")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(match.group(1) + "\n")
print(f"wrote {out} ({out.stat().st_size} bytes)")
PY
