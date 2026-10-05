#!/bin/bash
# build-okrapm.sh - compile the Okra package manager inside the Okra userland.
#
# This is the step that turns the bootstrap into scheme B. Up to here the
# package manager has only ever run on the host, next to the packages it
# installs. Here it is compiled by the compiler the bootstrap produced, inside
# the userland those packages make up, and packed by its own OPSIS packer, so
# the tool that manages the system is itself a product of the system.
#
# Two things are deliberately not used: cmake, which the userland does not
# carry, and the host's compiler, which would defeat the point. The sources are
# compiled straight with g++ and packed with the opsis that was just built from
# the same sources.
#
# Usage: build-okrapm.sh <rootfs-dir> <output-dir>
# Environment:
#   OKRA_OKRAPM_REPOSITORY  default https://github.com/OkraLinux/okrapm.git
#   OKRA_OKRAPM_REF         branch, tag or commit (default main)
#   GH_TOKEN                token, for a private repository or a rate limit
# Return: 0 when the archive is in <output-dir>, 1 otherwise.
set -uo pipefail

RootfsDirectory="${1:?usage: build-okrapm.sh <rootfs-dir> <output-dir>}"
OutputDirectory="${2:?usage: build-okrapm.sh <rootfs-dir> <output-dir>}"
OkrapmRepository="${OKRA_OKRAPM_REPOSITORY:-https://github.com/OkraLinux/okrapm.git}"
OkrapmRef="${OKRA_OKRAPM_REF:-main}"
Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
ScratchDirectory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-okrapm"

[ -d "$RootfsDirectory" ] || { echo "build-okrapm: no rootfs at $RootfsDirectory" >&2; exit 1; }
mkdir -p "$OutputDirectory" "$ScratchDirectory"

echo "== fetching the package manager sources"
rm -rf "$ScratchDirectory/source"
if [ -n "$Token" ]; then
	CloneUrl="https://x-access-token:$Token@${OkrapmRepository#https://}"
else
	CloneUrl="$OkrapmRepository"
fi
git clone -q --depth 1 --branch "$OkrapmRef" "$CloneUrl" "$ScratchDirectory/source" || {
	echo "build-okrapm: could not clone $OkrapmRepository" >&2
	exit 1
}
echo "== okrapm at $(git -C "$ScratchDirectory/source" rev-parse --short HEAD)"

# The file list is the one the package manager installs into a system: the two
# programs, and the OAA shell tools plus their shared library. Writing it here
# rather than taking the repository's copy keeps the payload in step with what
# this script actually builds.
cat > "$ScratchDirectory/source/package/okrapm.opsis" <<'OPSIS'
public class Package {
	public int MAIN(BuildContext ctx) {
		BeginPackage();
		PackFile(Environment("OPSIS_BIN_LUNAR"), "/usr/bin/lunar", "0755");
		PackFile(Environment("OPSIS_BIN_OPSIS"), "/usr/bin/opsis", "0755");
		PackFile(Environment("OPSIS_BIN_OAA"), "/usr/bin/oaa", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_NEW"), "/usr/lib/okrapm/oaa-new", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_BUILD"), "/usr/lib/okrapm/oaa-build", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_VERIFY"), "/usr/lib/okrapm/oaa-verify", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_EXTRACT"), "/usr/lib/okrapm/oaa-extract", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_INSPECT"), "/usr/lib/okrapm/oaa-inspect", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_LIST"), "/usr/lib/okrapm/oaa-list", "0755");
		PackFile(Environment("OPSIS_BIN_OAA_COMMON"), "/usr/lib/okrapm/oaatools-common.sh", "0644");
		FinishPackage();
		return 0;
	}
}
OPSIS

echo "== moving the sources into the userland"
InnerSource="$RootfsDirectory/usr/src/okrapm"
rm -rf "$InnerSource"
mkdir -p "$RootfsDirectory/usr/src"
cp -a "$ScratchDirectory/source" "$InnerSource"
rm -rf "$InnerSource/.git"

# The userland has to be able to run the compiler before it can build anything.
# A missing loader or a missing g++ is reported here rather than surfacing later
# as a compiler error.
for Required in usr/bin/g++ usr/bin/gcc usr/bin/make usr/bin/tar usr/bin/bash; do
	[ -e "$RootfsDirectory/$Required" ] || {
		echo "build-okrapm: the userland has no $Required" >&2
		exit 1
	}
done

echo "== compiling inside the userland"
cat > "$RootfsDirectory/usr/src/build-okrapm.sh" <<'INNER'
#!/bin/bash
# Runs inside the Okra userland. Nothing here may reach outside it.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=UTC
export HOME=/root
export SOURCE_DATE_EPOCH=1700000000

Source=/usr/src/okrapm
Build=/usr/src/okrapm-build
Out=/out
rm -rf "$Build"
mkdir -p "$Build" "$Out"

echo "== what is doing the compiling"
command -v g++ || { echo "no g++" >&2; exit 1; }
g++ --version | head -1
uname -m

# Shared source list: opsis and the lunar library, then the lunar front end.
Sources=(
	"$Source/opsis/src/engine.cpp"
	"$Source/lib/okrapmlib/src/version.cpp"
	"$Source/lib/okrapmlib/src/object.cpp"
	"$Source/lib/okrapmlib/src/object_ref.cpp"
	"$Source/lib/okrapmlib/src/operation.cpp"
	"$Source/lib/okrapmlib/src/transaction.cpp"
	"$Source/lib/okrapmlib/src/repository.cpp"
	"$Source/lib/okrapmlib/src/resolver.cpp"
	"$Source/lib/okrapmlib/src/system_store.cpp"
	"$Source/lib/okrapmlib/src/snapshot.cpp"
	"$Source/lib/okrapmlib/src/extension_api.cpp"
	"$Source/lib/okrapmlib/src/artifact_engine.cpp"
	"$Source/lib/okrapmlib/src/network_downloader.cpp"
	"$Source/lib/okrapmlib/src/pipeline_engine.cpp"
	"$Source/lib/okrapmlib/src/lunar_core.cpp"
)

Includes=(
	-I"$Source/opsis/include"
	-I"$Source/lib/okrapmlib/include"
	-I"$Source/include"
)

echo "== building opsis, the packer"
g++ -std=c++17 -O2 -D_GNU_SOURCE "${Includes[@]}" \
	"$Source/opsis/src/engine.cpp" "$Source/opsis/src/main.cpp" \
	-ldl -o "$Build/opsis" || { echo "opsis did not build" >&2; exit 1; }
"$Build/opsis" help >/dev/null 2>&1 || true
echo "== opsis runs"

echo "== building lunar, the package manager"
g++ -std=c++17 -O2 -D_GNU_SOURCE "${Includes[@]}" \
	"${Sources[@]}" \
	"$Source/src/lunar/src/main.cpp" "$Source/src/lunar/src/cli_text.cpp" \
	-ldl -o "$Build/lunar" || { echo "lunar did not build" >&2; exit 1; }
"$Build/lunar" help >/dev/null 2>&1 || { echo "lunar does not run" >&2; exit 1; }
echo "== lunar runs"

echo "== what lunar says about itself"
"$Build/lunar" help | head -4

# The OAA shell tools are not compiled; they are installed next to the programs
# that call them, so the payload below is complete.
mkdir -p "$Build/okrapm"
cp -a "$Source/oaatools/oaatools" "$Build/okrapm/oaa"
chmod +x "$Build/okrapm/oaa"
for Tool in oaa-new oaa-build oaa-verify oaa-extract oaa-inspect oaa-list; do
	cp -a "$Source/oaatools/$Tool" "$Build/okrapm/$Tool"
	chmod +x "$Build/okrapm/$Tool"
done
cp -a "$Source/oaatools/oaatools-common.sh" "$Build/okrapm/oaatools-common.sh"

echo "== packing the package manager with its own packer"
OPSIS_PKG_NAMESPACE=Okra \
OPSIS_PKG_NAME=okrapm \
OPSIS_PKG_VERSION=0.1.0 \
OPSIS_PKG_DESCRIPTION="Okra package manager" \
OPSIS_PKG_OUTPUT="$Out/Okra.okrapm.oaa" \
OPSIS_BUILD_DIR="$Build" \
OPSIS_BIN_LUNAR="$Build/lunar" \
OPSIS_BIN_OPSIS="$Build/opsis" \
OPSIS_BIN_OAA="$Build/okrapm/oaa" \
OPSIS_BIN_OAA_NEW="$Build/okrapm/oaa-new" \
OPSIS_BIN_OAA_BUILD="$Build/okrapm/oaa-build" \
OPSIS_BIN_OAA_VERIFY="$Build/okrapm/oaa-verify" \
OPSIS_BIN_OAA_EXTRACT="$Build/okrapm/oaa-extract" \
OPSIS_BIN_OAA_INSPECT="$Build/okrapm/oaa-inspect" \
OPSIS_BIN_OAA_LIST="$Build/okrapm/oaa-list" \
OPSIS_BIN_OAA_COMMON="$Build/okrapm/oaatools-common.sh" \
OPSIS_ALLOW_NONROOT=1 \
"$Build/opsis" pack --allow-nonroot "$Source/package/okrapm.opsis" \
	|| { echo "opsis pack failed" >&2; exit 1; }

[ -f "$Out/Okra.okrapm.oaa" ] || { echo "the packer produced no archive" >&2; exit 1; }
echo "== the package manager packaged itself"
ls -la "$Out"

# The archive becomes a repository entry, so what it declares is what the
# resolver will see. Printing it here saves a round trip when something is off.
echo "== what the archive declares"
tar -xOf "$Out/Okra.okrapm.oaa" ./meta.yaml 2>/dev/null || \
	tar --zstd -xOf "$Out/Okra.okrapm.oaa" ./meta.yaml 2>/dev/null || true
echo "== what the archive carries"
tar -tf "$Out/Okra.okrapm.oaa" 2>/dev/null | head -15 || \
	tar --zstd -tf "$Out/Okra.okrapm.oaa" 2>/dev/null | head -15 || true
INNER
chmod +x "$RootfsDirectory/usr/src/build-okrapm.sh"

# /out is where the archive comes back out; the sources are mounted read only
# so a build cannot modify them by accident.
mkdir -p "$RootfsDirectory/out"
for Point in proc sys dev dev/pts; do
	mkdir -p "$RootfsDirectory/$Point"
done
mount --bind /proc "$RootfsDirectory/proc" 2>/dev/null || true
mount --bind /sys "$RootfsDirectory/sys" 2>/dev/null || true
mount --bind /dev "$RootfsDirectory/dev" 2>/dev/null || true

CleanupMounts() {
	for Point in dev sys proc; do
		umount "$RootfsDirectory/$Point" 2>/dev/null || true
	done
}
trap CleanupMounts EXIT

chroot "$RootfsDirectory" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	/bin/bash /usr/src/build-okrapm.sh || {
	echo "build-okrapm: the in-userland build failed" >&2
	exit 1
}

CleanupMounts
trap - EXIT

Archive="$RootfsDirectory/out/Okra.okrapm.oaa"
[ -f "$Archive" ] || { echo "build-okrapm: no archive was produced" >&2; exit 1; }

# The packer writes the files and the size but not the dependencies, and the
# package manager cannot run without a libc. Adding it here keeps the archive
# honest about what it needs, and it is what puts glibc ahead of it in the
# transaction the resolver plans.
Repack="$ScratchDirectory/repack"
rm -rf "$Repack"
mkdir -p "$Repack"
if ! tar -xf "$Archive" -C "$Repack" 2>/dev/null &&
	! tar --zstd -xf "$Archive" -C "$Repack" 2>/dev/null; then
	echo "build-okrapm: cannot unpack the archive it just built" >&2
	exit 1
fi
if [ ! -f "$Repack/meta.yaml" ]; then
	echo "build-okrapm: the archive has no meta.yaml" >&2
	exit 1
fi
if ! grep -q '^dependencies:' "$Repack/meta.yaml"; then
	printf 'dependencies:\n  - app.glibc\n' >> "$Repack/meta.yaml"
	echo "== declared the libc dependency"
fi
"$ScratchDirectory/source/oaatools/oaa-build" "$Repack" -o "$Archive" || {
	echo "build-okrapm: repacking failed" >&2
	exit 1
}
echo "== the package manager declares"
cat "$Repack/meta.yaml"

cp -f "$Archive" "$OutputDirectory/"
sha256sum "$OutputDirectory/Okra.okrapm.oaa" | awk '{print $1"  Okra.okrapm.oaa"}' \
	> "$OutputDirectory/Okra.okrapm.oaa.sha256"

echo "== the package manager archive"
ls -la "$OutputDirectory"
cat "$OutputDirectory/Okra.okrapm.oaa.sha256"