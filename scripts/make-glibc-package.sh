#!/bin/bash
# make-glibc-package.sh - turn the toolchain sysroot into an app.glibc package.
#
# The cross toolchain builds glibc straight into okra-sysroot/, outside the
# package system, so every published package declares a dependency on app.glibc
# while no app.glibc archive exists. This script closes that gap: everything in
# the sysroot that no published package owns is the glibc base, and it is packed
# as a single OAA package.
#
# Ownership is decided from the packages themselves rather than from a hand
# written list, so a package that grows a file cannot silently end up with two
# owners.
#
# Environment:
#   OKRA_TOOLCHAIN           holds okra-sysroot (default /opt/okra-toolchain)
#   OKRA_SOURCE_REPOSITORY   default ylh440104/okra-oaa-packages-x86_64
#   OKRA_RELEASE             release tag holding the packages (default okra-userland)
#   OKRA_GLIBC_VERSION       version to record (default read from the sysroot)
#   OKRA_OUTPUT              archive directory (default <repo root>/out)
#   GH_TOKEN                 token to download the packages with
# Return: 0 when the archive and its checksum exist, 1 otherwise.
set -uo pipefail

ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
Sysroot="$ToolchainRoot/okra-sysroot"
SourceRepository="${OKRA_SOURCE_REPOSITORY:-ylh440104/okra-oaa-packages-x86_64}"
Release="${OKRA_RELEASE:-okra-userland}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
RepositoryRoot="${OKRA_REPO_ROOT:-$(cd "$ScriptDirectory/.." && pwd)}"
OutputDirectory="${OKRA_OUTPUT:-$RepositoryRoot/out}"
WorkRoot="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-glibc-package"
Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -d "$Sysroot" ] || { echo "make-glibc-package: no sysroot at $Sysroot" >&2; exit 1; }
[ -n "$Token" ] || { echo "make-glibc-package: GH_TOKEN must be set" >&2; exit 1; }

# ExtractMeta, for reading the packages' file lists.
. "$ScriptDirectory/lib-oaa.sh"

rm -rf "$WorkRoot"
# The packages are only read, never written, so a caller that already has them
# can hand over its directory and save a few hundred megabytes of downloads.
PackageCache="${OKRA_PACKAGE_CACHE:-$WorkRoot/packages}"
mkdir -p "$PackageCache" "$WorkRoot/stage/rootfs" "$OutputDirectory"

# Version() - read the glibc version out of the sysroot.
# Return: a version string such as 2.43.
Version() {
	if [ -n "${OKRA_GLIBC_VERSION:-}" ]; then
		printf '%s' "$OKRA_GLIBC_VERSION"
		return
	fi
	local Found
	Found="$(find "$Sysroot" -maxdepth 3 -name 'libc-2*.so' -print -quit 2>/dev/null)"
	if [ -n "$Found" ]; then
		basename "$Found" | sed 's/^libc-//; s/\.so$//'
		return
	fi
	printf '2.43'
}

GlibcVersion="$(Version)"
echo "== glibc version $GlibcVersion"

# DownloadPackages() - fetch every published .oaa so ownership can be read.
# Return: 0 on success, 1 when the list or a download fails.
DownloadPackages() {
	local Listing
	Listing="$(curl -sSL -m 120 \
		-H "Authorization: token $Token" \
		-H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$SourceRepository/releases/tags/$Release" 2>/dev/null)" || return 1
	printf '%s' "$Listing" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for a in data.get("assets", []):
    if a["name"].endswith(".oaa"):
        print(a["name"])
' > "$WorkRoot/names.txt" || return 1
	[ -s "$WorkRoot/names.txt" ] || return 1

	local Name
	while read -r Name; do
		[ -n "$Name" ] || continue
		[ -s "$PackageCache/$Name" ] && continue
		curl -sSL -m 600 -H "Authorization: token $Token" \
			-o "$PackageCache/$Name" \
			"https://github.com/$SourceRepository/releases/download/$Release/$Name" || return 1
	done < "$WorkRoot/names.txt"
	return 0
}

echo "== downloading the published packages to learn who owns what"
DownloadPackages || { echo "make-glibc-package: could not download the packages" >&2; exit 1; }
echo "== $(ls "$PackageCache" | wc -l) packages"

# CollectOwnership() - list the files the published packages claim.
# Return: 0. Writes one path per line to $WorkRoot/owned.txt.
#
# The meta.yaml is read with the tar command rather than Python's tarfile,
# which cannot read the zstd the archives use on the runner's Python.
CollectOwnership() {
	: > "$WorkRoot/owned.txt"
	local Archive
	for Archive in "$PackageCache"/*.oaa; do
		[ -f "$Archive" ] || continue
		ExtractMeta "$Archive" > "$WorkRoot/meta.txt" || {
			echo "make-glibc-package: no meta.yaml in $(basename "$Archive")" >&2
			continue
		}
		# The list ends at the next top level key, not at the first blank line,
		# so the section is tracked explicitly.
		awk '
			/^[A-Za-z_]+:/ { section = ($0 ~ /^files:/) ? "files" : ""; next }
			section == "files" && /^[[:space:]]+-/ {
				line = $0
				sub(/^[[:space:]]+-[[:space:]]*/, "", line)
				print line
			}
		' "$WorkRoot/meta.txt" >> "$WorkRoot/owned.txt"
	done
	sort -u "$WorkRoot/owned.txt" -o "$WorkRoot/owned.txt"
}

CollectOwnership
OwnedCount="$(wc -l < "$WorkRoot/owned.txt")"
echo "== the packages own $OwnedCount paths"
[ "$OwnedCount" -gt 100 ] || { echo "make-glibc-package: ownership looks empty" >&2; exit 1; }

# ListSysrootFiles() - list the sysroot entries that belong to the base.
# Return: 0. Writes one path per line to $WorkRoot/glibc.txt.
#
# A claimed path can be a directory - gcc claims /usr/lib/gcc, not the thousand
# files below it - so a file counts as owned when it equals a claim or sits
# under one. Without that, the whole gcc runtime would be claimed by glibc and
# the two packages would fight over it.
#
# /usr/src holds the sources the build scripts put there and is not part of the
# userland, so it is skipped.
ListSysrootFiles() {
	python3 - "$Sysroot" "$WorkRoot/owned.txt" > "$WorkRoot/glibc.txt" <<'PY'
import os, sys

sysroot, owned_path = sys.argv[1], sys.argv[2]
owned = set()
for line in open(owned_path):
    line = line.strip()
    if line:
        owned.add(line.rstrip('/'))


def is_owned(rel):
    if rel in owned:
        return True
    parent = os.path.dirname(rel)
    while parent and parent != '/':
        if parent in owned:
            return True
        parent = os.path.dirname(parent)
    return False


skip_tops = {'bin', 'sbin', 'etc', 'proc', 'sys', 'dev', 'run', 'root',
             'home', 'boot', 'tmp', 'var', 'src'}
out = []
for root, dirs, files in os.walk(sysroot):
    dirs[:] = [d for d in dirs if d != '.git']
    for name in files:
        full = os.path.join(root, name)
        rel = '/' + os.path.relpath(full, sysroot)
        parts = rel.split('/')
        if len(parts) < 2 or parts[1] in skip_tops:
            continue
        if rel.startswith('/usr/src'):
            continue
        if is_owned(rel):
            continue
        if os.path.islink(full) or os.path.isfile(full):
            out.append(rel)
for entry in sorted(out):
    print(entry)
PY
}

ListSysrootFiles
GlibcCount="$(wc -l < "$WorkRoot/glibc.txt")"
echo "== the sysroot adds $GlibcCount files on top"
[ "$GlibcCount" -gt 100 ] || { echo "make-glibc-package: the sysroot looks empty" >&2; exit 1; }

# CopyIntoStage() - copy the listed files, keeping symlinks as symlinks.
# Return: 0. Files listed but missing from the sysroot are reported.
CopyIntoStage() {
	python3 - "$Sysroot" "$WorkRoot/stage/rootfs" "$WorkRoot/glibc.txt" <<'PY'
import os, shutil, sys

sysroot, stage, listing = sys.argv[1], sys.argv[2], sys.argv[3]
missing = 0
count = 0
with open(listing) as handle:
    for line in handle:
        rel = line.strip()
        if not rel:
            continue
        source = sysroot + rel
        target = stage + rel
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.islink(source):
            if os.path.lexists(target):
                os.remove(target)
            os.symlink(os.readlink(source), target)
        elif os.path.isfile(source):
            shutil.copy2(source, target, follow_symlinks=False)
        else:
            missing += 1
            continue
        count += 1
print('copied %d entries' % count)
if missing:
    print('missing %d entries' % missing)
PY
}

echo "== staging the glibc base"
CopyIntoStage

cat > "$WorkRoot/stage/meta.yaml" <<EOF
name: glibc
namespace: app
version: $GlibcVersion
release: 1
description: "GNU C Library and the kernel headers it is built against"
architecture: x86_64
abi: OAABI1
maintainer: "ylh440104 <ylh440104@users.noreply.github.com>"
installed_size: $(du -sm "$WorkRoot/stage/rootfs" | cut -f1)
dependencies: []
files:
$(sed 's/^/  - /' "$WorkRoot/glibc.txt")
EOF

echo "== meta.yaml head"
head -12 "$WorkRoot/stage/meta.yaml"

# PackWithOaa() - build the archive with the oaatools from the Okrapm project.
# Return: 0 when the archive and its sidecar checksum exist.
PackWithOaa() {
	local Tools="${OKRA_OAATOOLS:-$RepositoryRoot/vendor/okrapm/oaatools}"
	if [ ! -x "$Tools/oaa-build" ]; then
		echo "make-glibc-package: no oaa-build at $Tools" >&2
		return 1
	fi
	local ArchiveName="glibc-$GlibcVersion-1.x86_64.oaa"
	"$Tools/oaa-build" "$WorkRoot/stage" -o "$OutputDirectory/$ArchiveName" || return 1
	[ -f "$OutputDirectory/$ArchiveName.sha256" ] || return 1
	echo "== built $ArchiveName"
	cat "$OutputDirectory/$ArchiveName.sha256"
	return 0
}

PackWithOaa || exit 1
echo "== done"
ls -la "$OutputDirectory"