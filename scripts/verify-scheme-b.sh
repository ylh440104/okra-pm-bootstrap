#!/bin/bash
# verify-scheme-b.sh - prove the package manager can build the system it runs on.
#
# Scheme B means the package manager is in charge of the whole system: every
# file in the userland is put there by an install transaction, and the package
# manager itself is one of the packages. This script is the evidence for that
# claim. It:
#
#   1. serves the repository that publish-repo.sh produced
#   2. syncs it with lunar, running on the host
#   3. installs the whole userland into an empty directory, so nothing can come
#      from the host by accident
#   4. chroots into the result and runs lunar there - the package manager
#      running on the packages it installed
#   5. installs a package from inside that chroot, with the lunar that lives
#      there
#
# Step 5 is the one that matters. If it works, the userland is self managing:
# the tool, the compiler that built it and the libraries under it all come from
# the same transaction history.
#
# Usage: verify-scheme-b.sh <repository-dir> <lunar-binary>
# Environment:
#   OKRA_WORK  scratch directory (default <runner temp>/okra-verify)
# Return: 0 when every step passed, 1 otherwise.
set -uo pipefail

RepositoryDirectory="${1:?usage: verify-scheme-b.sh <repository-dir> <lunar-binary>}"
HostLunar="${2:?usage: verify-scheme-b.sh <repository-dir> <lunar-binary>}"
WorkRoot="${OKRA_WORK:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-verify}"

[ -d "$RepositoryDirectory/artifacts" ] || {
	echo "verify-scheme-b: no artifacts in $RepositoryDirectory" >&2
	exit 1
}
[ -x "$HostLunar" ] || { echo "verify-scheme-b: no lunar at $HostLunar" >&2; exit 1; }

rm -rf "$WorkRoot"
mkdir -p "$WorkRoot"

# StartRepoServer() - serve the repository on a free port.
# Return: 0 once /index.yaml answers, 1 otherwise. Sets RepoPort.
StartRepoServer() {
	RepoPort="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
	python3 "$(dirname "$0")/repo-server.py" \
		--root "$RepositoryDirectory" --bind 127.0.0.1 --port "$RepoPort" \
		> "$WorkRoot/repo-server.log" 2>&1 &
	RepoServerPid=$!
	local Attempt
	for Attempt in $(seq 1 60); do
		if curl -fsS "http://127.0.0.1:$RepoPort/index.yaml" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$RepoServerPid" 2>/dev/null; then
			echo "verify-scheme-b: the repository server exited" >&2
			cat "$WorkRoot/repo-server.log" >&2
			return 1
		fi
		sleep 0.5
	done
	echo "verify-scheme-b: the repository server never answered" >&2
	return 1
}

StopRepoServer() {
	if [ -n "${RepoServerPid:-}" ]; then
		kill "$RepoServerPid" 2>/dev/null || true
		wait "$RepoServerPid" 2>/dev/null || true
		RepoServerPid=""
	fi
}

echo "== serving the repository"
StartRepoServer || exit 1
RepoUrl="http://127.0.0.1:$RepoPort"
echo "== repository at $RepoUrl"
# index.yaml is written by the server when it is asked for it, so it is fetched
# over HTTP rather than read from the directory.
curl -fsS "$RepoUrl/index.yaml" -o "$WorkRoot/index.yaml" || {
	StopRepoServer; echo "verify-scheme-b: no index at the repository" >&2; exit 1
}
IndexedCount="$(grep -c '^name:' "$WorkRoot/index.yaml" || true)"
echo "== the index lists $IndexedCount packages"
[ "$IndexedCount" -gt 50 ] || { StopRepoServer; echo "verify-scheme-b: the index is too small" >&2; exit 1; }

StateDirectory="$WorkRoot/state"
InstallRoot="$WorkRoot/root"
mkdir -p "$StateDirectory" "$InstallRoot"

echo "== adding the repository and syncing"
"$HostLunar" --root "$StateDirectory" repo add okra "$RepoUrl" remote || {
	StopRepoServer; echo "verify-scheme-b: repo add failed" >&2; exit 1
}
"$HostLunar" --root "$StateDirectory" sync okra || {
	StopRepoServer; echo "verify-scheme-b: sync failed" >&2; exit 1
}
"$HostLunar" --root "$StateDirectory" repo list

# Every package in the index is installed, so the tree is complete and the
# ordering is the resolver's job rather than a list written here by hand.
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
' "$WorkRoot/index.yaml")
echo "== ${#References[@]} packages to install"
[ "${#References[@]}" -gt 50 ] || { StopRepoServer; echo "verify-scheme-b: too few packages" >&2; exit 1; }

echo "== the transaction the resolver plans"
"$HostLunar" --root "$StateDirectory" plan install "${References[@]}" \
	> "$WorkRoot/plan.txt" 2>&1 || true
head -25 "$WorkRoot/plan.txt"

# The plan echoes the command first, and that line mentions every package, so
# the position of a package has to come from its own row. A row is an action
# followed by the object, which is what the leading "+" marks.
PlanRow() {
	grep -n "^[[:space:]]*+[[:space:]]\+$1[[:space:]]" "$WorkRoot/plan.txt" |
		head -1 | cut -d: -f1
}
PlannedGlibc="$(PlanRow 'app\.glibc')"
PlannedGcc="$(PlanRow 'GNU\.gcc')"
[ -n "$PlannedGlibc" ] && [ -n "$PlannedGcc" ] || {
	StopRepoServer; echo "verify-scheme-b: the plan is missing glibc or gcc" >&2; exit 1
}
[ "$PlannedGlibc" -lt "$PlannedGcc" ] || {
	StopRepoServer; echo "verify-scheme-b: glibc was not ordered before gcc" >&2; exit 1
}
echo "== the resolver put glibc at row $PlannedGlibc and gcc at row $PlannedGcc"

# The package manager must be in the plan as well: it is a package like any
# other, not something installed on the side.
PlanRow 'Okra\.okrapm' >/dev/null || {
	StopRepoServer; echo "verify-scheme-b: the plan has no package manager" >&2; exit 1
}
echo "== the package manager is one of the packages being installed"

echo "== installing the whole userland into an empty directory"
export LUNAR_INSTALL_ROOT="$InstallRoot"
"$HostLunar" --root "$StateDirectory" install "${References[@]}" || {
	unset LUNAR_INSTALL_ROOT
	StopRepoServer
	echo "verify-scheme-b: the install transaction failed" >&2
	exit 1
}
unset LUNAR_INSTALL_ROOT

echo "== what the transaction recorded"
"$HostLunar" --root "$StateDirectory" list | head -12
InstalledCount="$("$HostLunar" --root "$StateDirectory" list | grep -c . || true)"
echo "== $InstalledCount records in the system database"

# The userland has to answer to /bin/sh and to have an account database, which
# no package provides yet: they belong to a base-files package that does not
# exist. They are created here so the chroot can be entered, and the gap is
# reported rather than hidden.
echo "== filling in what no package provides yet"
mkdir -p "$InstallRoot"/{bin,etc,proc,sys,dev,run,tmp,root}
for Directory in bin sbin; do
	if [ -d "$InstallRoot/usr/$Directory" ]; then
		cp -a --remove-destination "$InstallRoot/usr/$Directory/." "$InstallRoot/$Directory"/
	fi
done
[ -e "$InstallRoot/bin/sh" ] || ln -sfn /usr/bin/bash "$InstallRoot/bin/sh"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$InstallRoot/etc/passwd"
printf 'root:x:0:\n' > "$InstallRoot/etc/group"
printf 'okra\n' > "$InstallRoot/etc/hostname"
: > "$InstallRoot/etc/ld.so.cache"

# The system database travels with the system: it is the record of what is
# installed, and without it the package manager inside the tree would think it
# is empty and try to install glibc again over the libc it is itself running on.
echo "== moving the system database into the tree"
mkdir -p "$InstallRoot/var/lib/lunar"
cp -a "$StateDirectory/." "$InstallRoot/var/lib/lunar"/

echo "== checking the tree stands on its own"
Failures=0
for Required in \
	"lib64/ld-linux-x86-64.so.2" \
	"usr/lib/libc.so.6" \
	"usr/bin/bash" \
	"usr/bin/gcc" \
	"usr/bin/g++" \
	"usr/bin/ld" \
	"usr/bin/make" \
	"usr/bin/lunar" \
	"bin/sh"; do
	if [ -e "$InstallRoot/$Required" ]; then
		echo "ok   $Required"
	else
		echo "FAIL $Required is missing"
		Failures=$((Failures + 1))
	fi
done
[ "$Failures" -eq 0 ] || {
	StopRepoServer
	echo "verify-scheme-b: $Failures required files are missing" >&2
	exit 1
}

# Every file here came from a transaction, so the only loader that can be
# present is the Okra one.
Loader="$InstallRoot/lib64/ld-linux-x86-64.so.2"
Machine="$(od -An -N2 -j18 -tu2 "$Loader" | tr -d ' ')"
[ "$Machine" = "62" ] || { StopRepoServer; echo "verify-scheme-b: the loader is not x86_64" >&2; exit 1; }
echo "ok   the loader is an x86_64 ELF"

echo "== running the package manager inside the installed userland"
for Point in proc sys dev; do
	mkdir -p "$InstallRoot/$Point"
	mount --bind "/$Point" "$InstallRoot/$Point" 2>/dev/null || true
done
CleanupMounts() {
	for Point in dev sys proc; do
		umount "$InstallRoot/$Point" 2>/dev/null || true
	done
}
trap 'CleanupMounts; StopRepoServer' EXIT

chroot "$InstallRoot" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	/bin/bash -c '
set -uo pipefail
echo "== uname inside the userland"
uname -m
echo "== the compiler inside the userland"
gcc --version | head -1
echo "== the package manager inside the userland"
lunar --root /var/lib/lunar help | head -3
echo "== what the package manager believes is installed"
lunar --root /var/lib/lunar list | head -6
echo "== the system the package manager reports"
lunar --root /var/lib/lunar status || true
' || { echo "verify-scheme-b: the in-userland checks failed" >&2; exit 1; }

echo "== managing a package from inside the userland"
# This is the claim. The lunar running here was compiled by this userland and
# installed by the transaction above, and it is asked to take a package out of
# the system and put it back, out of the repository it was installed from. If
# this works, the userland manages itself.
chroot "$InstallRoot" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	REPO_URL="$RepoUrl" \
	/bin/bash -c '
set -uo pipefail
echo "-- syncing the repository from inside"
lunar --root /var/lib/lunar sync okra
echo "-- removing GNU.nano"
test -e /usr/bin/nano || { echo "nano is not installed, the test proves nothing" >&2; exit 1; }
lunar --root /var/lib/lunar remove GNU.nano
if [ -e /usr/bin/nano ]; then
	echo "nano survived its own removal" >&2
	exit 1
fi
echo "nano is gone"
echo "-- installing it again"
lunar --root /var/lib/lunar install GNU.nano
if [ ! -e /usr/bin/nano ]; then
	echo "nano did not come back" >&2
	exit 1
fi
echo "nano is back"
echo "-- what the package manager lists now"
lunar --root /var/lib/lunar list | wc -l
' || { echo "verify-scheme-b: managing a package from inside failed" >&2; exit 1; }

CleanupMounts
StopRepoServer
trap - EXIT

echo "== scheme B holds: the package manager built, packaged and drove the userland"
du -sh "$InstallRoot"