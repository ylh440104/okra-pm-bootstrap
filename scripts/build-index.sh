#!/bin/bash
# build-index.sh - write index.yaml for a repository directory.
#
# The index is built from the archives that are present rather than from a list
# kept anywhere, so it is rebuilt whenever the contents change: after the
# repository is assembled, and again after the toolchain is repacked from the
# tree.
#
# Usage: build-index.sh <repository-dir>
# Return: 0 when the index was written, 1 otherwise.
set -uo pipefail

RepositoryDirectory="${1:?usage: build-index.sh <repository-dir>}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"

[ -d "$RepositoryDirectory/artifacts" ] || {
	echo "build-index: no artifacts in $RepositoryDirectory" >&2
	exit 1
}

python3 -c "
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('repo_server', '$ScriptDirectory/repo-server.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print('== wrote', module.write_index(Path('$RepositoryDirectory')))
" || exit 1

IndexedCount="$(grep -c '^name:' "$RepositoryDirectory/index.yaml" || true)"
echo "== the index lists $IndexedCount packages"
[ "$IndexedCount" -gt 50 ] || { echo "build-index: the index is too small" >&2; exit 1; }
echo "== done"