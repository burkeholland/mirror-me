"""Fail on credentials/private signing keys or runner names in public artifacts."""
import io
import os
import re
import sys
import zipfile
from pathlib import Path

FAIL = {
    "credential": re.compile(rb"\b(?:ghp|gho|ghu|github_pat)_[A-Za-z0-9_]{20,}\b|\bghs_[A-Za-z0-9]{30,}\b|\bAKIA[0-9A-Z]{16}\b"),
    "private key": re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"),
}
computer = os.environ.get("COMPUTERNAME", "")
if computer:
    FAIL["runner name"] = re.compile(rb"(?i)(?<![A-Za-z0-9_-])" + re.escape(computer.encode()) + rb"(?![A-Za-z0-9_-])")
SIGNING = re.compile(r"(?i)\.(pfx|p12|snk|pvk|key)$")
problems = []
scanned = 0


def scan(name, data):
    global scanned
    scanned += 1
    if SIGNING.search(name):
        problems.append(f"signing key file: {name}")
    if name.lower().endswith((".zip", ".nupkg", ".msix")):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    scan(f"{name}!/{info.filename}", archive.read(info))
        return
    for label, pattern in FAIL.items():
        if pattern.search(data) or pattern.search(data.replace(b"\x00", b"")):
            problems.append(f"{label}: {name}")


if len(sys.argv) < 2:
    raise SystemExit("Specify artifact directories or files")
for argument in sys.argv[1:]:
    root = Path(argument)
    if not root.exists():
        raise SystemExit(f"Artifact does not exist: {root}")
    files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
    if not files:
        raise SystemExit(f"Empty artifact: {root}")
    for path in files:
        scan(path.name if root.is_file() else str(path.relative_to(root)), path.read_bytes())
print(f"Scanned {scanned} files, including archive members.")
for problem in problems:
    print("PROBLEM", problem)
sys.exit(1 if problems else 0)
