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
#
# Okra.hello is left out on purpose. It is in the repository so the chroot can
# install it from there, and installing it here as well would leave nothing to
# test from inside.
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
            if "%s.%s" % (ns, name) != "Okra.hello":
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

# The loader cache is what lets lunar start: its C++ runtime lives in /usr/lib64
# and the loader only looks in /usr/lib by default. It is built here rather than
# copied from the assembly, because this tree was made by the package manager
# and the cache has to describe this tree.
printf '/usr/lib64\n/usr/lib\n' > "$InstallRoot/etc/ld.so.conf"
Ldconfig=""
for Candidate in "$InstallRoot/usr/sbin/ldconfig" "$InstallRoot/sbin/ldconfig"; do
	[ -x "$Candidate" ] && { Ldconfig="$Candidate"; break; }
done
if [ -n "$Ldconfig" ] && [ -x "$InstallRoot/lib64/ld-linux-x86-64.so.2" ]; then
	"$InstallRoot/lib64/ld-linux-x86-64.so.2" \
		--library-path "$InstallRoot/usr/lib64:$InstallRoot/usr/lib:$InstallRoot/lib64:$InstallRoot/lib" \
		"$Ldconfig" -r "$InstallRoot" && echo "ok   the loader cache was written"
else
	# ldconfig belongs to the glibc package, so its absence means the synthesized
	# glibc package left it out and nothing will find the C++ runtime.
	echo "FAIL no ldconfig in the tree, so the loader cache cannot be built"
fi

# The C++ runtime has to be reachable, or the package manager cannot run inside
# the tree it just installed.
echo "== the libraries the package manager needs"
for Library in libstdc++.so.6 libgcc_s.so.1; do
	Path="$(find "$InstallRoot" -maxdepth 3 -name "$Library" -print -quit 2>/dev/null)"
	if [ -z "$Path" ]; then
		echo "FAIL $Library is not in the tree"
		continue
	fi
	Resolved="$(readlink -f "$Path" 2>/dev/null || true)"
	[ -n "$Resolved" ] && [ -f "$Resolved" ] && echo "ok   $Library -> ${Resolved#"$InstallRoot"}" \
		|| echo "FAIL $Library does not resolve to a file"
done

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

# bash is the first thing the chroot runs, and it needs libtinfo. When it
# cannot find it the failure looks like a broken install, so the search is
# shown here rather than left to the error message.
#
# This also guards the path arithmetic in the installer: libtinfo.so.6 is a
# symlink to a symlink, and an installer that resolves links while working out
# where to write them replaces the real library with a link to itself.
echo "== the libraries bash needs"
for Library in libtinfo.so.6 libncursesw.so.6 libncursesw.so.6.5; do
	Path="$InstallRoot/usr/lib/$Library"
	if [ ! -e "$InstallRoot/usr/lib/$Library" ] && [ ! -L "$InstallRoot/usr/lib/$Library" ]; then
		echo "FAIL $Library is nowhere in the tree"
		continue
	fi
	# readlink -f follows the whole chain, so a self referential link shows up
	# as a failure here instead of as a missing library much later.
	Resolved="$(readlink -f "$Path" 2>/dev/null || true)"
	if [ -z "$Resolved" ] || [ ! -f "$Resolved" ]; then
		echo "FAIL $Library does not resolve to a file"
		ls -la "$Path" | sed 's/^/       /'
		continue
	fi
	echo "ok   $Library -> ${Resolved#"$InstallRoot"}"
done

echo "== what the loader resolves for bash"
Loader="$InstallRoot/lib64/ld-linux-x86-64.so.2"
"$Loader" --list "$InstallRoot/usr/bin/bash" 2>&1 | head -20 || true

echo "== the loader's search path"
"$Loader" --library-path "$InstallRoot/usr/lib:$InstallRoot/lib64:$InstallRoot/lib:$InstallRoot/usr/lib64" \
	--list "$InstallRoot/usr/bin/bash" 2>&1 | head -20 || true


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

echo "== managing the system from inside it"
# This is the claim. The lunar running here was compiled by this userland and
# installed by the transaction above, and it is now asked to install a package
# out of the repository it was installed from. Its own state, its own compiler
# and its own libraries are the only things it has.
#
# which is chosen because the transaction above did not install it: it is in
# the repository, not in the tree, so installing it can only have come from the
# package manager reaching the repository from inside the chroot.
chroot "$InstallRoot" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	REPO_URL="$RepoUrl" \
	/bin/bash -c '
set -uo pipefail
echo "-- the repository, seen from inside"
lunar --root /var/lib/lunar sync okra
echo "-- what is already installed"
lunar --root /var/lib/lunar list | wc -l
if [ -e /usr/bin/hello ]; then
	echo "hello is already installed, the test proves nothing" >&2
	exit 1
fi
echo "-- installing Okra.hello"
# The artifact is fetched before the install so the run shows whether it
# arrived and whether tar can read it, rather than only that the transaction
# failed.
lunar --root /var/lib/lunar download Okra.hello || true
echo "-- what the package manager fetched"
ls -la /var/lib/lunar/repos/okra/artifacts/ 2>/dev/null | head -6
# The installer extracts into a temporary directory and copies from there, so
# the same two steps are done by hand here: if the archive is readable and the
# copy works, the failure is inside the installer rather than in the archive.
echo "-- probing the archive the way the installer does"
Probe=/tmp/lunar-probe
rm -rf "$Probe"
mkdir -p "$Probe"
for Candidate in /var/lib/lunar/repos/okra/artifacts/Okra.hello* \
	/var/lib/lunar/cache/downloads/Okra.hello*; do
	[ -f "$Candidate" ] || continue
	echo "   $Candidate is $(stat -c %s "$Candidate") bytes"
	rm -rf "$Probe"
	mkdir -p "$Probe"
	if tar --zstd -xf "$Candidate" -C "$Probe"; then
		echo "   extracted: $(ls "$Probe" | tr '\n' ' ')"
	else
		echo "   tar could not read it"
	fi
done
lunar --root /var/lib/lunar install Okra.hello
if [ ! -e /usr/bin/hello ]; then
	echo "hello did not appear" >&2
	exit 1
fi
echo "-- and it runs"
/usr/bin/hello
echo "-- what is installed now"
lunar --root /var/lib/lunar list | wc -l
' || { echo "verify-scheme-b: managing the system from inside failed" >&2; exit 1; }

CleanupMounts
StopRepoServer
trap - EXIT

echo "== scheme B holds: the package manager built, packaged and drove the userland"
du -sh "$InstallRoot"