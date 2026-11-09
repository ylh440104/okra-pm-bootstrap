#!/bin/bash
# install-published-userland.sh - build a rootfs out of the published repository.
#
# The bootstrap proves the system can build itself and takes over two hours,
# almost all of it gcc. Adding a package does not need any of that: the compiler
# it needs was built by the bootstrap and is in the repository. This installs
# that repository into an empty directory, so the next step can compile
# something inside the result.
#
# What this is not: a bootstrap. Nothing here shows the system can build itself -
# that is scheme-b.yml, and it has already been shown. This is the build path,
# and it starts from binaries on purpose.
#
# Usage: install-published-userland.sh <rootfs-dir> <host-lunar> <repo-dir>
# Environment:
#   GH_TOKEN   token that can read the release
# Return: 0 when the tree has a working gcc and lunar in it.
set -uo pipefail

RootfsDirectory="${1:?usage: install-published-userland.sh <rootfs-dir> <host-lunar> <repo-dir>}"
HostLunar="${2:?usage: install-published-userland.sh <rootfs-dir> <host-lunar> <repo-dir>}"
RepositoryDirectory="${3:?usage: install-published-userland.sh <rootfs-dir> <host-lunar> <repo-dir>}"
Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
SourceRepository="${OKRA_REPOSITORY_SOURCE:-ylh440104/okra-pm-bootstrap}"
SourceRelease="${OKRA_REPOSITORY_RELEASE:-okra-repo}"
WorkRoot="$(dirname "$RootfsDirectory")/okra-install"

[ -n "$Token" ] || { echo "install-published-userland: GH_TOKEN must be set" >&2; exit 1; }

mkdir -p "$RepositoryDirectory/artifacts" "$WorkRoot"

# FetchReleased() - one asset from the release, two ways.
# @Name: asset name. @Target: where to put it.
# Return: 0 when the bytes are on disk.
#
# The release download URL goes through an asset CDN that answers 504 in bursts
# while api.github.com keeps answering, so a failed attempt is retried against
# the API endpoint before it is treated as missing.
FetchReleased() {
	local Name="$1" Target="$2"
	[ -s "$Target" ] && return 0
	curl -fsSL -m 900 --retry 2 --retry-delay 3 --retry-all-errors \
		-H "Authorization: token $Token" -o "$Target" \
		"https://github.com/$SourceRepository/releases/download/$SourceRelease/$Name" && return 0
	local Id
	Id="$(curl -sSL -m 120 -H "Authorization: token $Token" \
		"https://api.github.com/repos/$SourceRepository/releases/tags/$SourceRelease" |
		python3 -c '
import json, sys
name = sys.argv[1]
for a in json.load(sys.stdin).get("assets", []):
    if a["name"] == name:
        print(a["id"])
        break
' "$Name")"
	[ -n "$Id" ] || return 1
	curl -fsSL -m 900 --retry 2 --retry-delay 3 --retry-all-errors \
		-H "Authorization: token $Token" -H 'Accept: application/octet-stream' \
		-o "$Target" \
		"https://api.github.com/repos/$SourceRepository/releases/assets/$Id"
}

echo "== listing the published repository"
curl -sSL -m 120 -H "Authorization: token $Token" \
	-H 'Accept: application/vnd.github+json' \
	"https://api.github.com/repos/$SourceRepository/releases/tags/$SourceRelease" -o "$WorkRoot/release.json" || {
	echo "install-published-userland: could not reach the release" >&2
	exit 1
}
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for a in sorted(data.get("assets", []), key=lambda x: x["name"]):
    if a["name"].endswith(".oaa"):
        print(a["name"])
' "$WorkRoot/release.json" > "$WorkRoot/names.txt"
Count="$(wc -l < "$WorkRoot/names.txt")"
echo "== $Count packages to install"
[ "$Count" -gt 50 ] || { echo "install-published-userland: too few packages" >&2; exit 1; }

FetchReleased index.yaml "$RepositoryDirectory/index.yaml" || {
	echo "install-published-userland: no index in the release" >&2
	exit 1
}

Fetched=0
while read -r Name; do
	[ -n "$Name" ] || continue
	FetchReleased "$Name" "$RepositoryDirectory/artifacts/$Name" || {
		echo "install-published-userland: could not fetch $Name" >&2
		exit 1
	}
	FetchReleased "$Name.sha256" "$RepositoryDirectory/artifacts/$Name.sha256" || true
	Fetched=$((Fetched + 1))
done < "$WorkRoot/names.txt"
echo "== $Fetched archives are on disk"
du -sh "$RepositoryDirectory/artifacts" | sed 's/^/   /'

# The server builds index.yaml from the archives as it is asked for it, which
# keeps the index and the contents from disagreeing.
echo "== serving the repository"
# The port is chosen here and passed in rather than left to 0: the server prints
# the number it was given, not the one it bound, so asking for 0 reports 0 and
# the caller then tries to connect to port zero.
RepoPort="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
python3 "$ScriptDirectory/repo-server.py" \
	--root "$RepositoryDirectory" --bind 127.0.0.1 --port "$RepoPort" \
	> "$WorkRoot/repo-server.log" 2>&1 &
ServerPid=$!
Answered=0
for _ in $(seq 1 60); do
	if curl -fsS "http://127.0.0.1:$RepoPort/index.yaml" >/dev/null 2>&1; then
		Answered=1
		break
	fi
	if ! kill -0 "$ServerPid" 2>/dev/null; then
		break
	fi
	sleep 1
done
if [ "$Answered" -ne 1 ]; then
	cat "$WorkRoot/repo-server.log" >&2
	kill "$ServerPid" 2>/dev/null || true
	echo "install-published-userland: the repository server never answered" >&2
	exit 1
fi
RepoUrl="http://127.0.0.1:$RepoPort"
echo "== repository at $RepoUrl"

StateDirectory="$WorkRoot/state"
rm -rf "$StateDirectory" "$RootfsDirectory"
mkdir -p "$StateDirectory" "$RootfsDirectory"

"$HostLunar" --root "$StateDirectory" repo add okra "$RepoUrl" remote || {
	kill "$ServerPid" 2>/dev/null || true
	echo "install-published-userland: repo add failed" >&2
	exit 1
}
"$HostLunar" --root "$StateDirectory" sync okra || {
	kill "$ServerPid" 2>/dev/null || true
	echo "install-published-userland: sync failed" >&2
	exit 1
}

# The names come from the index rather than from a list written here, so a
# package added to the repository is installed without this script changing.
mapfile -t References < <(python3 -c '
import sys
ns = name = None
for line in open(sys.argv[1]):
    line = line.rstrip()
    if line.startswith("name:"):
        name = line.split(":", 1)[1].strip()
    elif line.startswith("namespace:"):
        ns = line.split(":", 1)[1].strip()
        if ns and name:
            print("%s.%s" % (ns, name))
            ns = name = None
' "$RepositoryDirectory/index.yaml" | sort -u)
[ "${#References[@]}" -gt 50 ] || {
	kill "$ServerPid" 2>/dev/null || true
	echo "install-published-userland: the repository offered too few packages" >&2
	exit 1
}

echo "== installing ${#References[@]} packages into an empty directory"
export LUNAR_INSTALL_ROOT="$RootfsDirectory"
"$HostLunar" --root "$StateDirectory" install "${References[@]}" || {
	unset LUNAR_INSTALL_ROOT
	kill "$ServerPid" 2>/dev/null || true
	echo "install-published-userland: the install transaction failed" >&2
	exit 1
}
unset LUNAR_INSTALL_ROOT
kill "$ServerPid" 2>/dev/null || true

# The mail is in the payload, the loader cache is not: it describes the tree it
# is in, so it is built here.
docker_ldconfig="$(find "$RootfsDirectory" -maxdepth 3 -name ldconfig -type f 2>/dev/null | head -1)"
if [ -n "$docker_ldconfig" ] && [ -x "$RootfsDirectory/lib64/ld-linux-x86-64.so.2" ]; then
	"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
		--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
		"$docker_ldconfig" -r "$RootfsDirectory" || true
fi
mkdir -p "$RootfsDirectory"/{proc,sys,dev,run,tmp}

[ -x "$RootfsDirectory/usr/bin/gcc" ] || {
	echo "install-published-userland: the tree has no gcc" >&2
	exit 1
}
echo "== the compiler in the tree"
"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
	--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
	"$RootfsDirectory/usr/bin/gcc" --version | head -1
echo "== done"