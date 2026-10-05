#!/usr/bin/env python3
"""repo-server.py - serve an OkraPM (Lunar) software source over HTTP.

Lunar syncs a repository by fetching /index.yaml, which is a concatenation of
the meta.yaml of every artifact, separated by "---" lines. It then resolves a
package to a file named "<namespace>.<name>@<version>.oaa" under /artifacts/.

This server keeps index.yaml in step with the artifacts directory on every
request, so a build can drop new archives in while the server is running.

Usage:
    repo-server.py --root <repository directory> [--bind 0.0.0.0] [--port 8765]
"""

from __future__ import annotations

import argparse
import subprocess
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Iterable, Optional

INDEX_LOCK = threading.Lock()

# Python's tarfile cannot read zstd before 3.14 and the runners are on 3.12, so
# the archives are read through the tar command. It also accepts the plain and
# gzip forms the packer may fall back to.
META_MEMBERS = ("./meta.yaml", "meta.yaml")
TAR_ATTEMPTS = (
    ["tar"],
    ["tar", "--zstd"],
    ["tar", "-z"],
    ["tar", "-J"],
    ["tar", "--lzma"],
)


def extract_meta(archive: Path) -> Optional[str]:
    """Read the meta.yaml out of an OAA archive, wherever it sits."""
    for member in META_MEMBERS:
        for prefix in TAR_ATTEMPTS:
            try:
                result = subprocess.run(
                    prefix + ["-xOf", str(archive), member],
                    capture_output=True,
                    timeout=120,
                )
            except Exception:
                continue
            if result.returncode == 0 and result.stdout:
                return result.stdout.decode("utf-8", errors="replace")
    return None


def iter_artifacts(repo_root: Path) -> Iterable[Path]:
    """Yield the .oaa files of a repository in a stable order."""
    artifacts = repo_root / "artifacts"
    if not artifacts.is_dir():
        return
    for path in sorted(artifacts.iterdir()):
        if path.suffix == ".oaa" and path.is_file():
            yield path


def build_index(repo_root: Path) -> str:
    """Concatenate every artifact's meta.yaml into a Lunar index."""
    chunks = []
    for archive in iter_artifacts(repo_root):
        meta = extract_meta(archive)
        if not meta or not meta.strip():
            chunks.append("# skipped %s: no readable meta.yaml" % archive.name)
            continue
        chunks.append(meta.strip())
    if not chunks:
        return ""
    return "\n---\n".join(chunks) + "\n"


def write_index(repo_root: Path) -> Path:
    """Rewrite index.yaml from the artifacts and return its path."""
    index = repo_root / "index.yaml"
    with INDEX_LOCK:
        index.write_text(build_index(repo_root), encoding="utf-8")
    return index


class RepoHandler(SimpleHTTPRequestHandler):
    """Serve the repository directory, refreshing index.yaml on demand."""

    repo_root: Path = Path(".")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(self.repo_root), **kwargs)

    def log_message(self, fmt: str, *args) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self) -> None:
        requested = self.path.split("?", 1)[0]
        if requested in ("/index.yaml", "/packages.idx"):
            data = write_index(self.repo_root).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if requested == "/":
            write_index(self.repo_root)
        super().do_GET()


def main() -> None:
    parser = argparse.ArgumentParser(description="OkraPM software source")
    parser.add_argument("--root", required=True, help="repository directory")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    repo_root = Path(args.root).resolve()
    (repo_root / "artifacts").mkdir(parents=True, exist_ok=True)
    index = write_index(repo_root)
    count = sum(1 for _ in iter_artifacts(repo_root))
    print("== repository at %s" % repo_root)
    print("== %d artifacts, index at %s" % (count, index))

    RepoHandler.repo_root = repo_root
    server = ThreadingHTTPServer((args.bind, args.port), RepoHandler)
    print("== listening on http://%s:%d/" % (args.bind, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n== stopped")


if __name__ == "__main__":
    main()
