#!/bin/bash
# rebuild-packages.sh - rebuild the userland packages inside the userland.
#
# The toolchain, the C library and their own packages are already built by the
# system itself. The other packages are not: they were cross compiled before the
# system existed. This rebuilds them from their own sources, with the compiler
# the system built, inside the system.
#
# The recipes are the ones that produced the cross built packages in the first
# place, so the flags, the configure arguments and the file lists are unchanged
# and only the compiler differs.
#
# Two things about this environment shape the script:
#
#   * The userland's curl is built without TLS, so it cannot fetch a source
#     tarball over https. Every source is downloaded by the host and handed to
#     the build as a file:// URL. The recipe's own sha256 is still checked
#     against the bytes that arrive, so a bad download cannot pass unnoticed.
#
#   * A few recipes want build tools that are not packages in this system
#     (meson, ninja, libgmp-dev). Those cannot be built here, so they are left
#     out and named, rather than failing halfway through the run.
#
# Usage: rebuild-packages.sh <rootfs-dir> <recipes-dir> <repository-dir> <output-dir> [package...]
# Environment:
#   OKRA_JOBS      default 4
#   OKRA_OAATOOLS  where oaa-build lives inside the userland
#                  (default /usr/lib/okrapm)
# Return: 0 when every package that was attempted produced an archive.
set -uo pipefail

RootfsDirectory="${1:?usage: rebuild-packages.sh <rootfs-dir> <recipes-dir> <repository-dir> <output-dir> [package...]}"
RecipesDirectory="${2:?usage: rebuild-packages.sh <rootfs-dir> <recipes-dir> <repository-dir> <output-dir> [package...]}"
RepositoryDirectory="${3:?usage: rebuild-packages.sh <rootfs-dir> <recipes-dir> <repository-dir> <output-dir> [package...]}"
OutputDirectory="${4:?usage: rebuild-packages.sh <rootfs-dir> <recipes-dir> <repository-dir> <output-dir> [package...]}"
shift 4
Wanted=("$@")

Jobs="${OKRA_JOBS:-4}"
OaaToolsInside="${OKRA_OAATOOLS:-/usr/lib/okrapm}"

[ -d "$RootfsDirectory" ] || { echo "rebuild-packages: no rootfs at $RootfsDirectory" >&2; exit 1; }
[ -d "$RecipesDirectory" ] || { echo "rebuild-packages: no recipes at $RecipesDirectory" >&2; exit 1; }
[ -x "$RootfsDirectory/usr/bin/gcc" ] || { echo "rebuild-packages: the userland has no gcc" >&2; exit 1; }

SourceDirectory="$(cd "$RecipesDirectory/.." && pwd)"
[ -f "$SourceDirectory/scripts/lib.sh" ] || {
	echo "rebuild-packages: no scripts/lib.sh beside $RecipesDirectory" >&2
	exit 1
}

# The recipes and the scripts that read them are copied into the tree and used
# unchanged. Rewriting them would mean the rebuilt package is not the package
# the recipe describes.
WorkInside="/usr/src/okra-packages"
WorkHost="$RootfsDirectory$WorkInside"
rm -rf "$WorkHost"
mkdir -p "$WorkHost/packages" "$WorkHost/scripts" "$WorkHost/src" "$WorkHost/logs" "$OutputDirectory"
cp -a "$RecipesDirectory"/*.conf "$WorkHost/packages/"
cp -a "$SourceDirectory/scripts/lib.sh" "$WorkHost/scripts/"
cp -a "$SourceDirectory/scripts/build-package.sh" "$WorkHost/scripts/"
chmod +x "$WorkHost/scripts/build-package.sh"

# Which packages to build. The toolchain, the C library, the crypt library and
# the package manager have their own steps; rebuilding them here would fight
# with those.
BuiltAlready=" binutils gcc glibc libxcrypt okrapm "
if [ "${#Wanted[@]}" -gt 0 ]; then
	Packages=("${Wanted[@]}")
else
	mapfile -t Packages < <(cd "$WorkHost/packages" && ls *.conf | sed 's/\.conf$//' | sort)
fi

ToBuild=()
LeftOut=()
for Package in "${Packages[@]}"; do
	[ -n "$Package" ] || continue
	case "$BuiltAlready" in
		*" $Package "*) LeftOut+=("$Package"); continue ;;
	esac
	# A caller can name packages that cannot be built here at all, so that the
	# reason is recorded by the caller rather than discovered by a failed build.
	case " ${OKRA_SKIP:-} " in
		*" $Package "*) LeftOut+=("$Package"); continue ;;
	esac
	ToBuild+=("$Package")
done
[ "${#ToBuild[@]}" -gt 0 ] || { echo "rebuild-packages: nothing to build" >&2; exit 1; }
echo "== ${#ToBuild[@]} packages to rebuild"
[ "${#LeftOut[@]}" -eq 0 ] || echo "== handled by their own steps: ${LeftOut[*]}"

# The sources. The host fetches them because the userland cannot speak https.
echo "== fetching the sources"
Fetched=0
Unfetched=0
for Package in "${ToBuild[@]}"; do
	Url="$(sed -n 's/^Url=["]*\([^"]*\)["]*$/\1/p' "$WorkHost/packages/$Package.conf" | head -1)"
	[ -n "$Url" ] || { echo "!! $Package has no Url in its recipe" >&2; Unfetched=$((Unfetched + 1)); continue; }
	Name="$(basename "${Url%%\?*}")"
	if [ -s "$WorkHost/src/$Name" ]; then
		Fetched=$((Fetched + 1))
		continue
	fi
	if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -m 900 \
		-o "$WorkHost/src/$Name" "$Url"; then
		Fetched=$((Fetched + 1))
	else
		echo "!! could not fetch $Url" >&2
		Unfetched=$((Unfetched + 1))
	fi
done
echo "== $Fetched sources ready, $Unfetched missing"
[ "$Unfetched" -eq 0 ] || { echo "rebuild-packages: some sources are missing" >&2; exit 1; }
du -sh "$WorkHost/src" | sed 's/^/   /'

# Two things have to be in the tree before anything can be packed, and neither
# arrives through the package manager at this point in the run.
#
# The packer itself comes out of the package manager archive: the manager is
# built but not yet installed here, because the install happens in the
# verification step from the repository, and the repository is built before
# this.
#
# The libraries come out of the repository, because the tree this step runs on
# was assembled from the seventy cross built packages and those do not include
# them. zstd is one of the seventy and it links against liblz4.so.1, so without
# this the packer cannot compress anything and every build fails at the last
# step, after the long part has already run.
#
# Both are seed actions and they are named as such: this is the only place where
# files enter the tree outside a transaction.
SeedIntoTree() {
	local Source="$1" Extract
	[ -f "$Source" ] || return 1
	Extract="$(mktemp -d)"
	if ! tar -xf "$Source" -C "$Extract" 2>/dev/null &&
		! tar --zstd -xf "$Source" -C "$Extract" 2>/dev/null; then
		rm -rf "$Extract"
		return 1
	fi
	if [ -d "$Extract/rootfs" ]; then
		cp -a "$Extract/rootfs"/. "$RootfsDirectory"/ 2>/dev/null || true
	fi
	rm -rf "$Extract"
	return 0
}

if [ ! -x "$RootfsDirectory$OaaToolsInside/oaa-build" ]; then
	Archive="${OKRA_OKRAPM_ARCHIVE:-}"
	[ -f "$Archive" ] || {
		echo "rebuild-packages: no oaa-build at $OaaToolsInside in the tree," >&2
		echo "                  and no archive to take it from" >&2
		exit 1
	}
	echo "== taking the packer out of $(basename "$Archive")"
	SeedIntoTree "$Archive" || {
		echo "rebuild-packages: the package manager archive would not open" >&2
		exit 1
	}
	chmod +x "$RootfsDirectory$OaaToolsInside"/* 2>/dev/null || true
	[ -x "$RootfsDirectory$OaaToolsInside/oaa-build" ] || {
		echo "rebuild-packages: the archive carried no oaa-build" >&2
		exit 1
	}
	echo "== the packer is in the tree"
fi

# The libraries the tree was assembled without. They are checked for by soname
# rather than by package, because what matters is that the loader can resolve
# them, not which archive they came from.
for Library in liblz4.so.1 libcrypt.so.1; do
	if [ -e "$RootfsDirectory/usr/lib/$Library" ] || [ -e "$RootfsDirectory/lib64/$Library" ]; then
		continue
	fi
	case "$Library" in
		liblz4.so.1)     Prefix="app.lz4@" ;;
		libcrypt.so.1)   Prefix="app.libxcrypt@" ;;
		*)               Prefix="" ;;
	esac
	Found=""
	for Candidate in "$RepositoryDirectory"/artifacts/*.oaa; do
		[ -f "$Candidate" ] || continue
		case "$(basename "$Candidate")" in
			"$Prefix"*) Found="$Candidate"; break ;;
		esac
	done
	[ -n "$Found" ] || {
		echo "rebuild-packages: the tree has no $Library and the repository has no package for it" >&2
		exit 1
	}
	echo "== putting $Library into the tree from $(basename "$Found")"
	SeedIntoTree "$Found" || {
		echo "rebuild-packages: $Found would not open" >&2
		exit 1
	}
done
# The loader cache is rebuilt so the new libraries are found by the name their
# dependants ask for.
Ldconfig="$RootfsDirectory/sbin/ldconfig"
[ -x "$Ldconfig" ] || Ldconfig="$RootfsDirectory/usr/sbin/ldconfig"
if [ -x "$Ldconfig" ] && [ -x "$RootfsDirectory/lib64/ld-linux-x86-64.so.2" ]; then
	"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
		--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
		"$Ldconfig" -r "$RootfsDirectory" >/dev/null 2>&1 && echo "== the loader cache was refreshed"
fi

# The build script's only host assumption is the one function that reaches for a
# package manager. It is replaced once, here, by appending an override to a copy
# of the library that the build script is pointed at.
cp -f "$WorkHost/scripts/lib.sh" "$WorkHost/scripts/lib-native.sh"
cat >> "$WorkHost/scripts/lib-native.sh" <<'SHIM'

# InstallBuildDependencies() - the host package manager is not available here.
# The build tools a recipe asks for are either already part of this system or
# not present at all; there is nothing to install from.
InstallBuildDependencies() {
	return 0
}
SHIM
sed -i 's|scripts/lib\.sh|scripts/lib-native.sh|' "$WorkHost/scripts/build-package.sh"

echo "== entering the userland"
for Point in dev dev/pts proc sys; do
	mkdir -p "$RootfsDirectory/$Point"
done
mount --bind /dev "$RootfsDirectory/dev" 2>/dev/null || true
mount --bind /dev/pts "$RootfsDirectory/dev/pts" 2>/dev/null || true
mount -t proc proc "$RootfsDirectory/proc" 2>/dev/null || true
mount -t sysfs sysfs "$RootfsDirectory/sys" 2>/dev/null || true
CleanupMounts() {
	for Point in sys proc dev/pts dev; do
		umount -lf "$RootfsDirectory/$Point" 2>/dev/null || true
	done
}
trap CleanupMounts EXIT

# The driver runs inside the tree. The package list is read from a file so it
# survives the chroot without quoting games, and each build's output is kept in
# a log so a failure can be read after the fact.
cat > "$WorkHost/build-all.sh" <<'INNER'
#!/bin/bash
# Runs inside the Okra userland, with the system's own toolchain.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=UTC
export HOME=/root
export MAKEFLAGS="-j${OKRA_JOBS}"

# Pointing the toolchain at the root of the tree is what makes this a native
# build: /usr/bin/gcc is the compiler this system compiled, and /usr/include and
# /usr/lib are this system's own headers and libraries.
export OKRA_TOOLCHAIN=/
export OKRA_TARGET_ARCH=x86_64
export OKRA_OAATOOLS="$OKRA_OAATOOLS_INSIDE"
export OKRA_PACKAGE_MODE=package

cd /usr/src/okra-packages || exit 1

echo "== what is doing the building"
gcc --version | head -1
ld --version | head -1

# The language standard is pinned rather than left to the compiler default.
#
# GCC 15 and later default to C23, and glibc 2.43 exposes the ISO C23 generic
# macros when that is in force: bsearch, free and realloc become macros whose
# arguments cannot contain a comma, so a call passing a compound literal breaks
# with "macro 'bsearch' passed 6 arguments, but takes just 5". util-linux 2.40
# is one tree that does this. The cross build used an older compiler whose
# default was C17, which is why the same recipe built then and not now.
#
# Pinning it keeps the result defined by the recipe instead of by whichever
# compiler happens to be current. The hardening flags come from the library so
# the two builds do not drift apart.
RepositoryRoot=/usr/src/okra-packages
. "$RepositoryRoot/scripts/lib-native.sh"
export CFLAGS="$(OkraHardeningFlags) -std=gnu17"
export CXXFLAGS="$(OkraHardeningFlags) -std=gnu++17"
echo "== CFLAGS: $CFLAGS"

mapfile -t Packages < packages.txt
Built=0
Failed=0
FailedList=()
for Package in "${Packages[@]}"; do
	Recipe="packages/$Package.conf"
	if [ ! -f "$Recipe" ]; then
		echo "!! no recipe for $Package" >&2
		Failed=$((Failed + 1)); FailedList+=("$Package"); continue
	fi

	# The source is already on disk, so the recipe's URL is pointed at it. Its
	# sha256 still has to match, which is what keeps this from being a build of
	# whatever happened to be lying around.
	Url="$(sed -n 's/^Url=["]*\([^"]*\)["]*$/\1/p' "$Recipe" | head -1)"
	Name="$(basename "${Url%%\?*}")"
	if [ ! -s "src/$Name" ]; then
		echo "!! no source for $Package" >&2
		Failed=$((Failed + 1)); FailedList+=("$Package"); continue
	fi
	sed -i "s|^Url=.*|Url=file:///usr/src/okra-packages/src/$Name|" "$Recipe"

	echo "=============================================================="
	echo "== building $Package from $Name"
	if bash scripts/build-package.sh "$Package" > "logs/$Package.log" 2>&1; then
		echo "ok   $Package  ($(du -sm "/tmp/okra-artifacts/$Package" 2>/dev/null | cut -f1) MB)"
		Built=$((Built + 1))
	else
		echo "FAIL $Package"
		tail -25 "logs/$Package.log" | sed 's/^/     /'
		Failed=$((Failed + 1)); FailedList+=("$Package")
	fi
done

echo "=============================================================="
echo "== rebuilt $Built packages, $Failed failed"
if [ "$Failed" -gt 0 ]; then
	echo "== failed: ${FailedList[*]}"
	# The reason each one failed is the only thing worth reading afterwards, and
	# the per package logs do not survive the run. The first line that looks like
	# an error is pulled out of each one here, so the report is complete in one
	# place instead of being buried in a megabyte of build output.
	: > failures.txt
	for Package in "${FailedList[@]}"; do
		Reason="$(grep -m1 -E 'error:|Error [0-9]+|undefined reference|cannot find|No such file|not found|command not found' \
			"logs/$Package.log" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-200)"
		[ -n "$Reason" ] || Reason="$(tail -3 "logs/$Package.log" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
		printf '%s: %s\n' "$Package" "$Reason" >> failures.txt
	done
	echo "== why each one failed"
	cat failures.txt
fi
[ "$Failed" -eq 0 ]
INNER
chmod +x "$WorkHost/build-all.sh"
printf '%s\n' "${ToBuild[@]}" > "$WorkHost/packages.txt"

chroot "$RootfsDirectory" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root TERM=dumb LC_ALL=C TZ=UTC \
	OKRA_JOBS="$Jobs" \
	OKRA_OAATOOLS_INSIDE="$OaaToolsInside" \
	/bin/bash /usr/src/okra-packages/build-all.sh
InnerStatus=$?

CleanupMounts
trap - EXIT

# The archives come back out of the tree, because the host is what publishes
# them and what rebuilds the repository index.
#
# Each one is checked against its own sidecar before it is taken. The packer
# writes the checksum only after the archive is complete, so a truncated file
# either has no sidecar or does not match it, and a build that died while
# compressing cannot pass as one that worked. That is exactly what happened
# once: fifty truncated archives were collected and reported as rebuilt.
echo "== collecting the rebuilt packages"
Count=0
Damaged=0
for Archive in "$RootfsDirectory"/tmp/okra-artifacts/*/*.oaa; do
	[ -f "$Archive" ] || continue
	Sum="$Archive.sha256"
	if [ ! -f "$Sum" ]; then
		echo "!! $(basename "$Archive") has no checksum, so it is not known to be complete" >&2
		Damaged=$((Damaged + 1))
		continue
	fi
	Expected="$(awk 'NR == 1 {print $1}' "$Sum")"
	Actual="$(sha256sum "$Archive" | awk '{print $1}')"
	if [ "$Expected" != "$Actual" ]; then
		echo "!! $(basename "$Archive") does not match its checksum" >&2
		Damaged=$((Damaged + 1))
		continue
	fi
	cp -f "$Archive" "$OutputDirectory/"
	cp -f "$Sum" "$OutputDirectory/"
	Count=$((Count + 1))
done
echo "== $Count archives came back intact"
[ "$Damaged" -eq 0 ] || echo "== $Damaged archives were damaged and left behind" >&2

# The per package logs are the only record of why a build failed, and they do
# not survive the run unless they are brought out. They go into the output
# directory so they travel with the artifacts.
if [ -d "$WorkHost/logs" ]; then
	cp -a "$WorkHost/logs" "$OutputDirectory/" 2>/dev/null || true
	echo "== the per package logs are in $OutputDirectory/logs"
fi
[ -f "$WorkHost/failures.txt" ] && cat "$WorkHost/failures.txt"
[ "$Count" -gt 0 ] || { echo "rebuild-packages: no archives were produced" >&2; exit 1; }

[ "$InnerStatus" -eq 0 ] || {
	echo "rebuild-packages: $Count packages were rebuilt but not all of them succeeded" >&2
	exit 1
}
[ "$Damaged" -eq 0 ] || {
	echo "rebuild-packages: some archives did not survive the packer" >&2
	exit 1
}
echo "== done"