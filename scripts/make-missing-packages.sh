#!/bin/bash
# make-missing-packages.sh - build the libraries the userland does not have.
#
# Every binary in the userland was checked for the shared libraries it asks for,
# and exactly two of them are nowhere in the tree:
#
#   liblz4.so.1     zstd links against it
#   libcrypt.so.1   the login tools link against it
#
# Neither is a cosmetic gap. tar shells out to zstd to read a zstd archive, so
# with zstd broken every .oaa in the repository fails to unpack from inside the
# system, which is the one thing scheme B has to be able to do. And the crypt
# library is what perl, shadow and sudo were borrowing from the runner while
# they were bootstrapped.
#
# Both are built here with the cross toolchain, which is what built everything
# else, and packed as ordinary packages so the package manager installs them
# like anything else. Nothing is copied into the tree by hand.
#
# Usage: make-missing-packages.sh <output-dir>
# Environment:
#   OKRA_TOOLCHAIN         holds cross/ and okra-sysroot (default /opt/okra-toolchain)
#   OKRA_TARGET_TRIPLE     default x86_64-okra-linux-gnu
#   OKRA_LZ4_VERSION       default 1.10.0
#   OKRA_LIBCRYPT_VERSION  default 4.4.36
#   OKRA_OAATOOLS          holds oaa-build (default <repo root>/vendor/okrapm/oaatools)
#   OKRA_JOBS              default 4
# Return: 0 when both archives and their checksums exist, 1 otherwise.
set -uo pipefail

OutputDirectory="${1:?usage: make-missing-packages.sh <output-dir>}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
RepositoryRoot="${OKRA_REPO_ROOT:-$(cd "$ScriptDirectory/.." && pwd)}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
TargetTriple="${OKRA_TARGET_TRIPLE:-x86_64-okra-linux-gnu}"
Jobs="${OKRA_JOBS:-4}"
Lz4Version="${OKRA_LZ4_VERSION:-1.10.0}"
LibcryptVersion="${OKRA_LIBCRYPT_VERSION:-4.4.36}"
OaaTools="${OKRA_OAATOOLS:-$RepositoryRoot/vendor/okrapm/oaatools}"

CrossGcc="$ToolchainRoot/cross/bin/$TargetTriple-gcc"
CrossAr="$ToolchainRoot/cross/bin/$TargetTriple-ar"
Sysroot="$ToolchainRoot/okra-sysroot"

[ -x "$CrossGcc" ] || { echo "make-missing-packages: no cross gcc at $CrossGcc" >&2; exit 1; }
[ -d "$Sysroot" ] || { echo "make-missing-packages: no sysroot at $Sysroot" >&2; exit 1; }
[ -x "$OaaTools/oaa-build" ] || { echo "make-missing-packages: no oaa-build at $OaaTools" >&2; exit 1; }

# The host triple for --build. The runner is x86_64, and naming it exactly is
# what makes configure treat this as a cross build and skip the tests it cannot
# run here.
BuildTriple="$(uname -m)-pc-linux-gnu"

WorkRoot="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-missing"
rm -rf "$WorkRoot"
mkdir -p "$WorkRoot" "$OutputDirectory"

echo "== cross compiler"
"$CrossGcc" --version | head -1

# Fetch() - download a source tarball.
# @Url, @Target. Return: 0 when the file is there and not empty.
Fetch() {
	local Url="$1" Target="$2"
	[ -s "$Target" ] && return 0
	echo "== fetching $(basename "$Target")"
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -m 900 -o "$Target" "$Url" || return 1
	[ -s "$Target" ] || return 1
	return 0
}

# CheckLibrary() - verify a staged shared library is what this system needs.
# @Library: absolute path inside the stage.
# @Soname: the soname it must carry.
# Return: 0 when it is an x86_64 ELF with that soname and no other library
#         dependency than the C library.
CheckLibrary() {
	local Library="$1" Soname="$2" Machine Actual Needs
	[ -f "$Library" ] || { echo "make-missing-packages: $Library was not produced" >&2; return 1; }
	Machine="$(od -An -N2 -j18 -tu2 "$Library" | tr -d ' ')"
	[ "$Machine" = "62" ] || {
		echo "make-missing-packages: $Library is not an x86_64 ELF" >&2
		return 1
	}
	Actual="$(readelf -d "$Library" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
	[ "$Actual" = "$Soname" ] || {
		echo "make-missing-packages: $Library has soname '$Actual', expected '$Soname'" >&2
		return 1
	}
	# A library that needs anything beyond the C library would be a package with
	# an undeclared dependency, which is how these gaps appeared in the first
	# place.
	Needs="$(readelf -d "$Library" 2>/dev/null |
		sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | grep -v '^libc\.so\.6$' || true)"
	[ -z "$Needs" ] || {
		echo "make-missing-packages: $Library also needs: $Needs" >&2
		return 1
	}
	echo "ok   $(basename "$Library") carries soname $Soname and needs only the C library"
	return 0
}

# PackStage() - turn a staging tree into a package.
#
# The file list is walked out of the stage rather than written by hand, so the
# package declares exactly what it installs and nothing is left out.
#
# @Stage: holds rootfs/ with the files at their final paths.
# @Namespace, @Name, @Version, @Description.
# @ArchiveName: the human name the pipeline renames from.
# Return: 0 when the archive and its checksum exist.
PackStage() {
	local Stage="$1" Namespace="$2" Name="$3" Version="$4" Description="$5" ArchiveName="$6"
	local Listing="$WorkRoot/$Name.files"

	( cd "$Stage/rootfs" && find . -mindepth 1 \( -type f -o -type l \) -printf '/%P\n' | LC_ALL=C sort ) \
		> "$Listing"
	local Count
	Count="$(wc -l < "$Listing")"
	[ "$Count" -gt 0 ] || { echo "make-missing-packages: $Name staged nothing" >&2; return 1; }

	{
		echo "name: $Name"
		echo "namespace: $Namespace"
		echo "version: $Version"
		echo "release: 1"
		echo "description: \"$Description\""
		echo "architecture: x86_64"
		echo "abi: OAABI1"
		echo "maintainer: \"ylh440104 <ylh440104@users.noreply.github.com>\""
		echo "installed_size: $(du -sm "$Stage/rootfs" | cut -f1)"
		echo "dependencies:"
		echo "  - app.glibc"
		echo "files:"
		sed 's/^/  - /' "$Listing"
	} > "$Stage/meta.yaml"

	"$OaaTools/oaa-build" "$Stage" -o "$OutputDirectory/$ArchiveName" || return 1
	[ -f "$OutputDirectory/$ArchiveName" ] || return 1
	[ -f "$OutputDirectory/$ArchiveName.sha256" ] || return 1
	echo "== packed $ArchiveName with $Count entries"
	return 0
}

# BuildLz4() - build the compression library zstd loads.
#
# zstd is a package in the repository and tar calls it to read every .oaa, so
# this is what makes the repository installable from inside the system.
# Return: 0 when app.lz4 is in the output directory.
BuildLz4() {
	local Stage="$WorkRoot/lz4-stage"
	local Source="$WorkRoot/lz4-src"
	echo "== building lz4 $Lz4Version for the userland"
	Fetch "https://github.com/lz4/lz4/releases/download/v$Lz4Version/lz4-$Lz4Version.tar.gz" \
		"$WorkRoot/lz4.tar.gz" || return 1
	rm -rf "$Source" "$Stage"
	mkdir -p "$Source" "$Stage"
	tar -xf "$WorkRoot/lz4.tar.gz" -C "$Source" --strip-components=1 || return 1

	# lz4's build is a plain Makefile. Only lib/ is built: the command line tool
	# is not what anything in the tree is missing, and leaving it out keeps the
	# package to the one library that was absent.
	make -C "$Source/lib" -j"$Jobs" CC="$CrossGcc" AR="$CrossAr" || return 1
	make -C "$Source/lib" install DESTDIR="$Stage/rootfs" PREFIX=/usr LIBDIR=/usr/lib \
		CC="$CrossGcc" AR="$CrossAr" || return 1

	# The stage is trimmed to the runtime library and its two names. Headers and
	# a static archive would be a development package, and this one exists to
	# make zstd load.
	local Keep="$Stage/rootfs/usr/lib/liblz4.so.1.10.0"
	[ -f "$Keep" ] || Keep="$(find "$Stage/rootfs" -name 'liblz4.so.1.*' -print -quit 2>/dev/null)"
	[ -n "$Keep" ] && [ -f "$Keep" ] || {
		echo "make-missing-packages: lz4 produced no versioned library" >&2
		return 1
	}
	local Versioned
	Versioned="$(basename "$Keep")"
	local Trimmed="$WorkRoot/lz4-trimmed"
	rm -rf "$Trimmed"
	mkdir -p "$Trimmed/rootfs/usr/lib"
	cp -a "$Keep" "$Trimmed/rootfs/usr/lib/$Versioned"
	( cd "$Trimmed/rootfs/usr/lib" && ln -sfn "$Versioned" liblz4.so.1 )

	CheckLibrary "$Trimmed/rootfs/usr/lib/$Versioned" liblz4.so.1 || return 1
	PackStage "$Trimmed" app lz4 "$Lz4Version" \
		"LZ4 compression library, which zstd loads" "lz4-$Lz4Version-1.x86_64.oaa"
}

# BuildLibxcrypt() - build the crypt library the login tools load.
#
# glibc stopped shipping libcrypt after 2.28. perl, shadow and sudo were
# bootstrapped while borrowing the runner's copy, so the userland has none and
# those tools cannot start without it.
# Return: 0 when app.libxcrypt is in the output directory.
BuildLibxcrypt() {
	local Stage="$WorkRoot/libxcrypt-stage"
	local Source="$WorkRoot/libxcrypt-src"
	echo "== building libxcrypt $LibcryptVersion for the userland"
	Fetch "https://github.com/besser82/libxcrypt/releases/download/v$LibcryptVersion/libxcrypt-$LibcryptVersion.tar.xz" \
		"$WorkRoot/libxcrypt.tar.xz" || return 1
	rm -rf "$Source" "$Stage"
	mkdir -p "$Source" "$Stage"
	tar -xf "$WorkRoot/libxcrypt.tar.xz" -C "$Source" --strip-components=1 || return 1

	# --enable-obsolete-api=glibc is what produces libcrypt.so.1 with the
	# XCRYPT_2.0 version, which is the interface the bootstrapped packages were
	# linked against. Without it the library is named libcrypt.so.2 and nothing
	# in the tree would find it.
	( cd "$Source" &&
		CC="$CrossGcc" AR="$CrossAr" \
		./configure --host="$TargetTriple" --build="$BuildTriple" \
			--prefix=/usr --disable-static --disable-werror \
			--enable-hashes=strong,glibc --enable-obsolete-api=glibc ) || return 1
	make -C "$Source" -j"$Jobs" || return 1
	make -C "$Source" install DESTDIR="$Stage/rootfs" || return 1

	local Real
	Real="$(find "$Stage/rootfs/usr/lib" -maxdepth 1 -name 'libcrypt.so.1.*' -print -quit 2>/dev/null)"
	[ -n "$Real" ] || {
		echo "make-missing-packages: libxcrypt produced no libcrypt.so.1" >&2
		return 1
	}
	CheckLibrary "$Real" libcrypt.so.1 || return 1
	PackStage "$Stage" app libxcrypt "$LibcryptVersion" \
		"Password hashing library, which glibc stopped shipping" \
		"libxcrypt-$LibcryptVersion-1.x86_64.oaa"
}

BuildLz4 || exit 1
BuildLibxcrypt || exit 1

echo "== the packages that were missing"
ls -la "$OutputDirectory"
echo "== done"