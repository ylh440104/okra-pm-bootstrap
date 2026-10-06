#!/bin/bash
# repack-native-toolchain.sh - pack the toolchain the system built for itself.
#
# rebuild-native.sh and rebuild-libc.sh compile binutils, gcc and glibc inside
# the userland and install them into the tree. What they do not do is tell the
# package manager: the system database still records the cross built archives,
# and the repository still serves them. So the tree runs on a toolchain that no
# package describes.
#
# This closes that gap. The toolchain the system compiled is packed as an
# ordinary package, with the same identity as the one it replaces and a bumped
# release, so the repository and the tree agree again. That is the step the
# bootstrap document calls the completion marker: rebuild the toolchain with
# itself, then package the result.
#
# The file list comes from the package being replaced rather than from a scan of
# the tree. A scan would sweep in everything under /usr, including the package
# manager and the sample package, and produce one enormous package instead of
# three that match what they replace.
#
# Usage: repack-native-toolchain.sh <rootfs-dir> <packages-dir> <repository-dir> <output-dir>
# Environment:
#   OKRA_OAATOOLS  holds oaa-build (default <repo root>/vendor/okrapm/oaatools)
#   OKRA_REPACK_RELEASE  release to record (default 2)
# Return: 0 when every toolchain package was repacked, 1 otherwise.
set -uo pipefail

RootfsDirectory="${1:?usage: repack-native-toolchain.sh <rootfs-dir> <packages-dir> <repository-dir> <output-dir>}"
PackagesDirectory="${2:?usage: repack-native-toolchain.sh <rootfs-dir> <packages-dir> <repository-dir> <output-dir>}"
RepositoryDirectory="${3:?usage: repack-native-toolchain.sh <rootfs-dir> <packages-dir> <repository-dir> <output-dir>}"
OutputDirectory="${4:?usage: repack-native-toolchain.sh <rootfs-dir> <packages-dir> <repository-dir> <output-dir>}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
RepositoryRoot="${OKRA_REPO_ROOT:-$(cd "$ScriptDirectory/.." && pwd)}"
OaaTools="${OKRA_OAATOOLS:-$RepositoryRoot/vendor/okrapm/oaatools}"
Release="${OKRA_REPACK_RELEASE:-2}"

[ -d "$RootfsDirectory" ] || { echo "repack: no rootfs at $RootfsDirectory" >&2; exit 1; }
[ -d "$PackagesDirectory" ] || { echo "repack: no packages at $PackagesDirectory" >&2; exit 1; }
[ -x "$OaaTools/oaa-build" ] || { echo "repack: no oaa-build at $OaaTools" >&2; exit 1; }

. "$ScriptDirectory/lib-oaa.sh"

WorkRoot="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-repack"
rm -rf "$WorkRoot"
mkdir -p "$WorkRoot" "$OutputDirectory"

# RepackOne() - repack the files of one published package from the tree.
#
# @Pattern: glob for the archive being replaced, such as 'gcc-*-1.x86_64*.oaa'.
# Return: 0 when a new archive and its checksum were written, 1 otherwise.
#
# The archive being replaced is looked for in the repository as well as in the
# download directory: app.glibc is synthesized by this workflow rather than
# downloaded, so it only exists in the repository. The repository keeps its
# archives one level down, in artifacts/, which is why both levels are searched.
RepackOne() {
	local Pattern="$1" Source=""
	local Directory
	for Directory in "$RepositoryDirectory" "$RepositoryDirectory/artifacts" \
		"$PackagesDirectory" "$PackagesDirectory/artifacts"; do
		[ -d "$Directory" ] || continue
		Source="$(find "$Directory" -maxdepth 1 -name "$Pattern" -print -quit 2>/dev/null)"
		[ -n "$Source" ] && break
	done
	if [ -z "$Source" ]; then
		echo "repack: no archive matching $Pattern in $RepositoryDirectory or $PackagesDirectory" >&2
		return 1
	fi

	local Namespace Name Version
	Namespace="$(ExtractMetaField "$Source" namespace || true)"
	Name="$(ExtractMetaField "$Source" name || true)"
	Version="$(ExtractMetaField "$Source" version || true)"
	[ -n "$Namespace" ] && [ -n "$Name" ] && [ -n "$Version" ] || {
		echo "repack: cannot read the identity of $(basename "$Source")" >&2
		return 1
	}
	echo "== repacking $Namespace.$Name $Version from the tree"

	local Stage="$WorkRoot/$Name-stage"
	rm -rf "$Stage"
	mkdir -p "$Stage/rootfs"

	# The file list is read out of the archive being replaced and expanded: an
	# entry can be a directory, which means everything under it. Each file is
	# copied from the tree, so what goes into the new package is what the system
	# compiled, not what was shipped.
	ExtractMeta "$Source" > "$WorkRoot/$Name.meta" || return 1
	python3 - "$RootfsDirectory" "$Stage/rootfs" "$WorkRoot/$Name.meta" <<'PY'
import os, shutil, sys

root, stage, meta = sys.argv[1], sys.argv[2], sys.argv[3]

# Only the files: section is read, and it ends at the next top level key rather
# than at the first blank line.
listing = []
section = None
for line in open(meta):
    line = line.rstrip('\n')
    if line and not line[0].isspace() and ':' in line:
        section = 'files' if line.startswith('files:') else None
        continue
    if section == 'files' and line.strip().startswith('- '):
        entry = line.strip()[2:].strip().strip('"')
        if entry:
            listing.append(entry)

if not listing:
    print('the archive declares no files', file=sys.stderr)
    sys.exit(1)

# A directory entry covers everything below it, so the list is expanded against
# the tree rather than against the archive.
expanded = []
for entry in listing:
    full = root + entry
    if os.path.islink(full) or os.path.isfile(full):
        expanded.append(entry)
    elif os.path.isdir(full):
        for base, dirs, files in os.walk(full):
            for name in files:
                path = os.path.join(base, name)
                expanded.append('/' + os.path.relpath(path, root))

copied = missing = 0
seen = set()
absent = []
for entry in expanded:
    if entry in seen:
        continue
    seen.add(entry)
    source = root + entry
    target = stage + entry
    if os.path.islink(source):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.lexists(target):
            os.remove(target)
        os.symlink(os.readlink(source), target)
    elif os.path.isfile(source):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    else:
        missing += 1
        absent.append(entry)
        continue
    copied += 1

print('staged %d entries, %d declared but absent from the tree' % (copied, missing))
if missing:
    # The names matter more than the count: they say how the native build
    # differs from the cross one, which is what has to be understood before the
    # package can be replaced by it.
    print('repack: the tree is missing files the package declares:', file=sys.stderr)
    for entry in absent[:25]:
        print('    %s' % entry, file=sys.stderr)
    if len(absent) > 25:
        print('    ... and %d more' % (len(absent) - 25), file=sys.stderr)
    sys.exit(1)
if copied < 10:
    print('repack: only %d entries were staged' % copied, file=sys.stderr)
    sys.exit(1)
PY
	[ "$?" -eq 0 ] || return 1

	# The point of the exercise is that these are the binaries the system built,
	# so they are checked for the target before being packed. A cross built
	# archive would be x86_64 as well, so this is not what proves it; the
	# fingerprint the rebuild scripts printed is. This catches the other
	# mistake, which is staging something that is not an ELF at all.
	local Machine Checked=0
	while IFS= read -r Candidate; do
		head -c 4 "$Candidate" | grep -q $'\x7fELF' || continue
		Machine="$(od -An -N2 -j18 -tu2 "$Candidate" | tr -d ' ')"
		[ "$Machine" = "62" ] || {
			echo "repack: $Candidate is not an x86_64 ELF" >&2
			return 1
		}
		Checked=$((Checked + 1))
	done < <(find "$Stage/rootfs" -type f 2>/dev/null)
	echo "ok   $Checked x86_64 ELF files staged"

	{
		echo "name: $Name"
		echo "namespace: $Namespace"
		echo "version: $Version"
		echo "release: $Release"
		echo "description: \"$(ExtractMetaField "$Source" description || echo '') (built by the system itself)\""
		echo "architecture: x86_64"
		echo "abi: OAABI1"
		echo "maintainer: \"ylh440104 <ylh440104@users.noreply.github.com>\""
		echo "installed_size: $(du -sm "$Stage/rootfs" | cut -f1)"
		echo "dependencies:"
		echo "  - app.glibc"
		echo "files:"
		( cd "$Stage/rootfs" && find . -mindepth 1 \( -type f -o -type l \) -printf '/%P\n' | LC_ALL=C sort ) |
			sed 's/^/  - /'
	} > "$Stage/meta.yaml"

	local ArchiveName="$Namespace.$Name@$Version.oaa"
	# The name has to be the one the resolver asks for, which is the normalised
	# version rather than the one written in the meta.yaml: 2.44 becomes 2.44.0
	# and 16.2 becomes 16.2.0. Without this the repacked archive lands beside the
	# cross built one under a different name, and the install would fetch the
	# cross built one.
	local Normalised
	if Normalised="$(LunarVersion "$Version")"; then
		ArchiveName="$Namespace.$Name@$Normalised.oaa"
	fi
	"$OaaTools/oaa-build" "$Stage" -o "$OutputDirectory/$ArchiveName" || return 1
	[ -f "$OutputDirectory/$ArchiveName" ] || return 1
	[ -f "$OutputDirectory/$ArchiveName.sha256" ] || return 1
	echo "== repacked $ArchiveName"
	return 0
}

RepackOne 'binutils-*-1.x86_64*.oaa' || exit 1
RepackOne 'gcc-*-1.x86_64*.oaa' || exit 1
# glibc is named differently in each place: the synthesized archive is called
# glibc-<version>-1.x86_64.oaa, and the rename in publish-repo.sh gives it the
# name the resolver asks for. Both are accepted so this does not depend on which
# side of that step the repository is read from.
RepackOne 'app.glibc@*.oaa' || RepackOne 'glibc-*-1.x86_64*.oaa' || exit 1

# The packages the userland rebuilt for itself are already packed, because the
# packer inside the userland did it. They only need the names the resolver asks
# for, which is the same rename everything else goes through.
if [ -n "${OKRA_REBUILT_DIRECTORY:-}" ] && [ -d "$OKRA_REBUILT_DIRECTORY" ]; then
	echo "== taking in the packages the userland rebuilt for itself"
	mkdir -p "$OutputDirectory/rebuilt"
	cp -a "$OKRA_REBUILT_DIRECTORY"/. "$OutputDirectory/rebuilt/"
	bash "$ScriptDirectory/rename-to-lunar.sh" "$OutputDirectory/rebuilt" || {
		echo "repack: the rebuilt packages could not all be renamed" >&2
		exit 1
	}
	RebuiltCount="$(ls "$OutputDirectory/rebuilt"/*.oaa 2>/dev/null | wc -l)"
	echo "== the userland rebuilt $RebuiltCount packages"
	[ "$RebuiltCount" -gt 50 ] || {
		echo "repack: far fewer packages came back than were attempted" >&2
		exit 1
	}
fi

# The repacked archives replace the ones the repository was carrying, so the
# repository describes what the system actually runs on, and the index is
# rebuilt because the file lists have changed. This is done before the
# verification so the tree that is installed and inspected is the native one.
echo "== putting the repacked toolchain into the repository"
for Source in "$OutputDirectory"/*.oaa "$OutputDirectory"/rebuilt/*.oaa; do
	[ -f "$Source" ] || continue
	Name="$(basename "$Source")"
	rm -f "$RepositoryDirectory/artifacts/$Name" "$RepositoryDirectory/artifacts/$Name.sha256"
	cp -f "$Source" "$RepositoryDirectory/artifacts/$Name"
	[ -f "$Source.sha256" ] && cp -f "$Source.sha256" "$RepositoryDirectory/artifacts/$Name.sha256"
	echo "== replaced $Name"
done
bash "$ScriptDirectory/build-index.sh" "$RepositoryDirectory" || exit 1

echo "== the toolchain the system built for itself"
ls -la "$OutputDirectory"
echo "== done"