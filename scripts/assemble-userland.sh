#!/bin/bash
# assemble-userland.sh - put the toolchain sysroot and the packages into a rootfs.
#
# This builds the tree that the package manager is compiled in. It is a plain
# layering operation on purpose: the toolchain sysroot holds the glibc the cross
# toolchain built, and the bootstrapped packages are copied on top of it. The
# point of the exercise is what happens next - lunar installing that same tree
# into an empty directory from scratch - so this step stays mechanical and
# obvious.
#
# Usage: assemble-userland.sh <rootfs-dir> <archive-dir>
# Environment:
#   OKRA_TOOLCHAIN  holds okra-sysroot (default /opt/okra-toolchain)
# Return: 0 when the rootfs is complete enough to chroot into, 1 otherwise.
set -uo pipefail

RootfsDirectory="${1:?usage: assemble-userland.sh <rootfs-dir> <archive-dir>}"
ArchiveDirectory="${2:?usage: assemble-userland.sh <rootfs-dir> <archive-dir>}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
Sysroot="$ToolchainRoot/okra-sysroot"

[ -d "$Sysroot" ] || { echo "assemble-userland: no sysroot at $Sysroot" >&2; exit 1; }
[ -d "$ArchiveDirectory" ] || { echo "assemble-userland: no archives at $ArchiveDirectory" >&2; exit 1; }

echo "== laying down the toolchain sysroot"
mkdir -p "$RootfsDirectory"
# --remove-destination so a package that replaces an entry which is already a
# symlink writes a real file instead of following the link elsewhere.
cp -a --remove-destination "$Sysroot/." "$RootfsDirectory"/

echo "== layering the bootstrapped packages"
Layered=0
while IFS= read -r Archive; do
	[ -n "$Archive" ] || continue
	Scratch="$(mktemp -d)"
	if ! tar --zstd -xf "$Archive" -C "$Scratch" 2>/dev/null &&
		! tar -xf "$Archive" -C "$Scratch" 2>/dev/null; then
		echo "assemble-userland: cannot unpack $Archive" >&2
		rm -rf "$Scratch"
		exit 1
	fi
	if [ ! -d "$Scratch/rootfs" ]; then
		echo "assemble-userland: $Archive has no rootfs directory" >&2
		rm -rf "$Scratch"
		exit 1
	fi
	cp -a --remove-destination "$Scratch/rootfs/." "$RootfsDirectory"/
	rm -rf "$Scratch"
	Layered=$((Layered + 1))
done < <(find "$ArchiveDirectory" -name '*.oaa' | sort)
echo "== layered $Layered archives"
[ "$Layered" -gt 50 ] || { echo "assemble-userland: too few archives" >&2; exit 1; }

echo "== filling in the directories a system needs"
mkdir -p "$RootfsDirectory"/{bin,sbin,etc,var,tmp,proc,sys,dev,run,root,home,boot,usr/src,out}

for Directory in bin sbin; do
	if [ -d "$RootfsDirectory/usr/$Directory" ]; then
		cp -a --remove-destination "$RootfsDirectory/usr/$Directory/." "$RootfsDirectory/$Directory"/
	fi
done

[ -e "$RootfsDirectory/bin/sh" ] || ln -sfn /usr/bin/bash "$RootfsDirectory/bin/sh"

# The standard names a build system calls are not owned by any package, because
# on a host they belong to the distribution: gcc only ships /usr/bin/gcc, and
# makefiles say "cc".
for Link in cc:gcc c++:g++ pkg-config:pkgconf; do
	Name="${Link%%:*}"
	Target="${Link##*:}"
	for Directory in usr/bin bin; do
		if [ -x "$RootfsDirectory/$Directory/$Target" ] && [ ! -e "$RootfsDirectory/$Directory/$Name" ]; then
			ln -sfn "$Target" "$RootfsDirectory/$Directory/$Name"
		fi
	done
done

# gcc installs the C++ runtime and libgcc_s under /usr/lib64, and the loader is
# only compiled with /usr/lib in its default search path, so lunar cannot start
# until the loader is told about that directory. The account files above and the
# cache below are what make it work: ldconfig reads ld.so.conf and writes
# ld.so.cache, which is how every distribution solves this. It runs through the
# loader rather than chroot, so assembling a tree does not need root.
#
# /lib and /usr/lib64 are in the list because packages install into them:
# util-linux puts libuuid.so.1 in /lib, which leaves /usr/lib/libuuid.so pointing
# at a file the loader was never told about. Python then fails to import _uuid
# with "libuuid.so.1: cannot open shared object file" even though the library is
# right there in the tree.
echo "== writing the loader configuration"
cat > "$RootfsDirectory/etc/ld.so.conf" <<'EOF'
/usr/lib64
/usr/lib
/lib64
/lib
EOF

RunLdconfig() {
	local Tree="$1" Loader="$1/lib64/ld-linux-x86-64.so.2" Candidate
	[ -x "$Loader" ] || return 1
	# glibc installs it as /usr/sbin/ldconfig with /sbin as a link on a merged
	# system, so both are tried rather than assuming one.
	for Candidate in "$Tree/usr/sbin/ldconfig" "$Tree/sbin/ldconfig"; do
		[ -x "$Candidate" ] || continue
		"$Loader" --library-path "$Tree/usr/lib64:$Tree/usr/lib:$Tree/lib64:$Tree/lib" \
			"$Candidate" -r "$Tree" || return 1
		return 0
	done
	return 1
}

if RunLdconfig "$RootfsDirectory"; then
	echo "ok   the loader cache was written"
else
	echo "== ldconfig could not be run here; the cache will be built on first boot"
fi

echo "== writing the account files"
cat > "$RootfsDirectory/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/:/bin/false
EOF
cat > "$RootfsDirectory/etc/group" <<'EOF'
root:x:0:
wheel:x:10:
nobody:x:65534:
EOF
printf 'okra\n' > "$RootfsDirectory/etc/hostname"

echo "== checking the rootfs"
Failures=0
for Required in \
	"lib64/ld-linux-x86-64.so.2" \
	"usr/lib/libc.so.6" \
	"usr/bin/bash" \
	"usr/bin/gcc" \
	"usr/bin/g++" \
	"usr/bin/ld" \
	"usr/bin/make" \
	"usr/bin/tar" \
	"bin/sh"; do
	if [ -e "$RootfsDirectory/$Required" ]; then
		echo "ok   $Required"
	else
		echo "FAIL $Required is missing"
		Failures=$((Failures + 1))
	fi
done
[ "$Failures" -eq 0 ] || { echo "assemble-userland: $Failures files are missing" >&2; exit 1; }

Loader="$RootfsDirectory/lib64/ld-linux-x86-64.so.2"
Machine="$(od -An -N2 -j18 -tu2 "$Loader" | tr -d ' ')"
[ "$Machine" = "62" ] || { echo "assemble-userland: the loader is not x86_64" >&2; exit 1; }
echo "ok   the loader is an x86_64 ELF"

echo "== the rootfs is ready"
du -sh "$RootfsDirectory"
ls "$RootfsDirectory/usr/bin" | wc -l