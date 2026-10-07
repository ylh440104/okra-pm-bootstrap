#!/bin/bash
# patch-recipes-for-native.sh - take the host out of the recipes.
#
# The recipes were written for a build that ran on a full host, and a few of
# them reach for something that only exists there. That was invisible while the
# builds ran on the runner; run inside this system they fail, and the failure
# reads as a broken package rather than as a missing host tool.
#
# Every change is either a single line substituted in place, or an override
# appended to the end of the recipe. A recipe is sourced, so a Build() defined at
# the end replaces one defined earlier; that keeps multi-line changes readable
# instead of trying to push them through sed.
#
# The patches live here rather than in the recipes because the recipes are what
# produced the packages that already exist, and rewriting them wholesale would
# make it impossible to say which build made which archive.
#
# Usage: patch-recipes-for-native.sh <recipes-dir>
# Return: 0 when every patch applied, 1 when one of them no longer matches.
set -uo pipefail

RecipesDirectory="${1:?usage: patch-recipes-for-native.sh <recipes-dir>}"
[ -d "$RecipesDirectory" ] || { echo "patch-recipes: no recipes at $RecipesDirectory" >&2; exit 1; }

Failures=0

# Substitute() - replace one line of a recipe.
# @File: recipe name without the .conf suffix.
# @From: the text to replace, as a basic regular expression.
# @To: what to replace it with.
# @Note: why, printed so the log carries the reason.
# Return: 0 when the file changed, 1 otherwise.
Substitute() {
	local File="$RecipesDirectory/$1.conf" From="$2" To="$3" Note="$4" Found
	[ -f "$File" ] || { echo "patch-recipes: no $1.conf" >&2; Failures=$((Failures + 1)); return 1; }
	Found="$(grep -c "$From" "$File" || true)"
	if [ "$Found" -eq 0 ]; then
		echo "patch-recipes: $1.conf no longer contains the pattern" >&2
		echo "               looking for: $From" >&2
		Failures=$((Failures + 1))
		return 1
	fi
	sed -i "s|$From|$To|g" "$File"
	echo "== patched $1: $Note"
	return 0
}

# Append() - add a block to the end of a recipe.
# @File: recipe name without the .conf suffix.
# @Note: why, printed so the log carries the reason.
# Reads the block from standard input.
# Return: 0 when the block was added, 1 when the recipe is absent.
Append() {
	local File="$RecipesDirectory/$1.conf" Note="$2"
	[ -f "$File" ] || { echo "patch-recipes: no $1.conf" >&2; Failures=$((Failures + 1)); return 1; }
	cat >> "$File"
	echo "== patched $1: $Note"
	return 0
}

echo "== taking the host out of the recipes"

# fakeroot is not a package in this system and cannot be built without it. It
# exists to make install write root-owned entries into a staging tree, which
# this build does not need: the package manager records ownership when it
# installs, and the staging tree is only read by the packer.
Substitute sudo 'fakeroot make DESTDIR=' 'make DESTDIR=' \
	'install no longer goes through fakeroot, which this system does not have'

# lzip is not a package either. The source is a .tar.lz, which the build script
# unpacks with lzip, so the host unpacks it first and the build is pointed at the
# plain tar instead. auto is the same extraction the lz case does, without the
# lzip step.
Substitute ed 'ArchiveFormat=lz' 'ArchiveFormat=auto' \
	'the .tar.lz is unpacked by the host, so the build sees a plain tar'

# coreutils' configure calls hostname, which is one of the programs this package
# provides, so the call cannot succeed while it is being built. The answer only
# sets a variable in a test, so an empty one is used.
Append coreutils 'configure calls hostname, which this package is what provides' <<'RECIPE'

# The configure script calls hostname, which is one of the programs this package
# provides. It cannot exist yet, and the answer only sets a variable in a test,
# so a stub that prints an empty line is put in front of it for the whole build.
Build() {
	cd "$SourceDirectory"
	StubDirectory="$(mktemp -d)"
	printf '#!/bin/sh\nprintf "\\n"\n' > "$StubDirectory/hostname"
	chmod +x "$StubDirectory/hostname"
	PATH="$StubDirectory:$PATH" ./configure --prefix=/usr --disable-nls
	PATH="$StubDirectory:$PATH" make -j"$(nproc)"
	make DESTDIR="$InstallRoot" install
	rm -rf "$StubDirectory"
}
RECIPE

# strace 6.13 assigns a pointer to const into a non-const one, which this tree
# turns into an error. The one warning is downgraded rather than switching the
# flag off globally, so the change is visible here and does not hide the same
# mistake anywhere else.
Append strace 'strace assigns a const pointer, which this tree makes an error' <<'RECIPE'

# ioctl.c assigns a pointer to const into a non-const one. This tree promotes
# that warning to an error, and the flag is downgraded for this build only.
Build() {
	cd "$SourceDirectory"
	CFLAGS="$CFLAGS -Wno-error=discarded-qualifiers" \
		./configure --prefix=/usr --disable-nls --disable-mpers --enable-mpers=no \
			--without-libdw --without-libunwind
	make -j"$(nproc)"
	make DESTDIR="$InstallRoot" install
}
RECIPE

# procps and dialog both fail to find ncurses, and ncurses itself installs no
# pkg-config file and no non-wide libncurses.so, so a build that looks for
# either of those finds nothing. Both are provided here rather than in the
# ncurses recipe, because the ncurses package in the repository was already
# built from that recipe and changing it would make the two disagree.
Append ncurses 'install the names and the pkg-config file a build looks for' <<'RECIPE'

# The configure script of anything that links ncurses looks for one of these,
# and the recipe above installs neither: only the wide library and the versioned
# names are put in place. They are added to the same install tree, so the package
# that is built from this recipe carries them.
Build() {
	cd "$SourceDirectory"
	./configure --prefix=/usr --with-shared --without-ada --without-tests \
		--disable-nls --without-cxx-binding --with-shared-only --disable-stripping
	make -j"$(nproc)"
	make DESTDIR="$InstallRoot" install

	cd "$InstallRoot/usr/lib" || exit 1
	WideLibrary="libncurses.so.6"
	[ -e libncursesw.so.6 ] && WideLibrary="libncursesw.so.6"
	ln -sf "$WideLibrary" libtinfo.so.6
	ln -sf "$WideLibrary" libncurses.so.6
	ln -sf "$WideLibrary" libcurses.so.6
	# The linker looks for the unversioned name, which nothing provided.
	ln -sf "$WideLibrary" libncurses.so
	ln -sf "$WideLibrary" libtinfo.so
	ln -sf "$WideLibrary" libcurses.so

	# Anything using pkg-config to find ncurses needs these, and ncurses 6.5
	# only writes them when the wide and narrow builds are both enabled.
	PkgDirectory="$InstallRoot/usr/lib/pkgconfig"
	mkdir -p "$PkgDirectory"
	for Module in ncurses ncursesw tinfo; do
		cat > "$PkgDirectory/$Module.pc" <<PC
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: $Module
Description: ncurses terminal library
Version: 6.5
Libs: -L\${libdir} -l$Module
Libs.private: -lm
Cflags: -I\${includedir}
PC
	done
}
RECIPE

[ "$Failures" -eq 0 ] || {
	echo "patch-recipes: $Failures patches did not apply" >&2
	exit 1
}
echo "== done"