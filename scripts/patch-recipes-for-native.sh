#!/bin/bash
# patch-recipes-for-native.sh - take the host out of the recipes.
#
# The recipes were written for a build that ran on a full host, and a few of
# them reach for something that only exists there. That was invisible while the
# builds ran on the runner; run inside this system they fail, and the failure
# reads as a broken package rather than as a missing host tool.
#
# The patches live here rather than in the recipes because the recipes are what
# produced the packages that already exist, and rewriting them wholesale would
# make it impossible to say which build made which archive.
#
# Every change is a literal text substitution that has to match, or a block
# appended to the end of the recipe. A recipe is sourced, so a Build() defined at
# the end replaces one defined earlier. The edits are done in Python rather than
# sed because several of them are multi-line, and because a literal match that
# cannot be found is a mistake worth stopping for rather than a silent no-op.
#
# Usage: patch-recipes-for-native.sh <recipes-dir>
# Return: 0 when every patch applied, 1 when one of them no longer matches.
set -uo pipefail

[ "$#" -eq 1 ] || {
	echo "usage: patch-recipes-for-native.sh <recipes-dir>" >&2
	exit 1
}

exec python3 - "$1" <<'PYTHON'
import os
import sys

Recipes = sys.argv[1]
if not os.path.isdir(Recipes):
    sys.exit('patch-recipes: no recipes at %s' % Recipes)

Failures = 0


def Substitute(File, From, To, Note):
    """Replace one piece of text in one recipe, and say so."""
    global Failures
    Path = os.path.join(Recipes, File + '.conf')
    if not os.path.isfile(Path):
        print('patch-recipes: no %s.conf' % File, file=sys.stderr)
        Failures += 1
        return
    Text = open(Path).read()
    if From not in Text:
        print('patch-recipes: %s.conf no longer contains the pattern' % File, file=sys.stderr)
        print('               looking for: %s' % From, file=sys.stderr)
        Failures += 1
        return
    open(Path, 'w').write(Text.replace(From, To, 1))
    print('== patched %s: %s' % (File, Note))


def Append(File, Note, Block):
    """Add a block to the end of one recipe."""
    global Failures
    Path = os.path.join(Recipes, File + '.conf')
    if not os.path.isfile(Path):
        print('patch-recipes: no %s.conf' % File, file=sys.stderr)
        Failures += 1
        return
    with open(Path, 'a') as Handle:
        Handle.write(Block)
    print('== patched %s: %s' % (File, Note))


print('== taking the host out of the recipes')

# fakeroot is not a package in this system and cannot be built without it. It
# exists to make install write root-owned entries into a staging tree, which this
# build does not need: the package manager records ownership when it installs,
# and the staging tree is only read by the packer.
Substitute(
    'sudo',
    'fakeroot make DESTDIR=',
    'make DESTDIR=',
    'install no longer goes through fakeroot, which this system does not have')

# lzip is not a package either. The source is a .tar.lz, and the build script
# would unpack it with lzip, which does not exist here.
#
# The tar in this tree cannot stand in for it: GNU tar recognises .lz and runs
# lzip itself. So the host unpacks the archive, and the recipe is pointed at the
# plain tar, which is what auto extracts.
Substitute(
    'ed',
    'ArchiveFormat=lz',
    'ArchiveFormat=auto',
    'the host unpacks the .tar.lz, so the build is handed a plain tar')

# coreutils and tar both refuse to run configure as root unless they are told it
# is safe. The build runs as root inside the tree, which is what makes the check
# fire, and this is the variable upstream provides for exactly that.
for Package in ('coreutils', 'tar'):
    Substitute(
        Package,
        'ConfigureFlags=(--disable-nls)',
        'ConfigureFlags=(--disable-nls)\n'
        '# The build runs as root inside the tree, which is what the check is for.\n'
        'export FORCE_UNSAFE_CONFIGURE=1',
        'configure is told the build really is meant to run as root')

# util-linux 2.40.4 calls bsearch with a compound literal that ends in a comma:
#
#     if (bsearch(&(struct pollfd){.fd = fd,}, local.iov_base, ...
#
# When _ISOC23_SOURCE is in force, glibc defines bsearch as a macro over a
# compound literal, and the comma inside the argument is read as an argument
# separator, so the compiler reports
#
#     macro 'bsearch' passed 6 arguments, but takes just 5
#
# _GNU_SOURCE turns _ISOC23_SOURCE on whatever -std says, which is why pinning
# the language standard did not help. The trailing comma is what makes it
# ambiguous, so the trailing comma is what goes.
#
# The call is in the source, not in the recipe, so the edit happens inside the
# recipe's Build().
Append(
    'util-linux',
    'the compound literal no longer ends in a comma inside the bsearch call',
    r'''
# lsfd.c calls bsearch with a compound literal that ends in a comma. When
# _ISOC23_SOURCE is in force, glibc defines bsearch as a macro over a compound
# literal and the comma inside the argument is read as an argument separator:
#
#     error: macro 'bsearch' passed 6 arguments, but takes just 5
#
# _GNU_SOURCE turns _ISOC23_SOURCE on whatever -std says, so the trailing comma
# is what has to go. It is the only occurrence of this shape in the tree.
Build() {
	cd "$SourceDirectory"
	sed -i 's|bsearch(&(struct pollfd){\.fd = fd,}|bsearch(\&(struct pollfd){.fd = fd }|' \
		misc-utils/lsfd.c
	./configure --prefix=/usr --disable-nls --without-python --disable-bash-completion \
		--disable-asciidoc --disable-use-tty-group --disable-makeinstall-chown \
		--disable-liblastlog2 --without-udev --without-systemd
	make -j"$(nproc)"
	make DESTDIR="$InstallRoot" install
}
''')

# perl 5.40 does not compile its locale code here:
#
#     locale.c:8812:43: error: 'PERL_LC_ALL_CATEGORY_POSITIONS_INIT' undeclared
#
# The macro is defined in perl.h only inside this block:
#
#     #  if defined(USE_FAKE_LC_ALL_POSITIONAL_NOTATION)
#        && defined(PERL_LC_ALL_USES_NAME_VALUE_PAIRS)
#     #    define PERL_LC_ALL_CATEGORY_POSITIONS_INIT { 12, 11, 10, ... }
#
# so both macros have to be present. Configure decides them by compiling a
# program that asks the C library how it separates the categories inside LC_ALL
# and prints the answer. Here that program prints nothing, so Configure records
# "name=value pairs" as false and leaves PERL_LC_ALL_USES_NAME_VALUE_PAIRS
# undefined. The code path for that case then needs the macro above, which only
# exists for the notation that was just ruled out.
#
# Both are passed in one -Accflags, not two: Configure treats -Accflags as an
# assignment, so a second one would replace the first rather than add to it.
Substitute(
    'perl',
    '-Dman1ext=1 -Dman3ext=3pm',
    '-Dman1ext=1 -Dman3ext=3pm'
    ' -Accflags=-DUSE_FAKE_LC_ALL_POSITIONAL_NOTATION\\ -DPERL_LC_ALL_USES_NAME_VALUE_PAIRS',
    'the LC_ALL syntax probe is skipped and the positional notation is assumed')

# coreutils' configure calls hostname, which is one of the programs this package
# provides, so the call cannot succeed while it is being built. The answer only
# sets a variable in a test, so an empty one is used.
Append(
    'coreutils',
    'configure calls hostname, which this package is what provides',
    r'''
# The configure script calls hostname, which is one of the programs this package
# provides. It cannot exist yet, and the answer only sets a variable in a test,
# so a stub that prints an empty line is put in front of it for the whole build.
Build() {
	cd "$SourceDirectory"
	StubDirectory="$(mktemp -d)"
	printf '#!/bin/sh\nprintf "\n"\n' > "$StubDirectory/hostname"
	chmod +x "$StubDirectory/hostname"
	PATH="$StubDirectory:$PATH" ./configure --prefix=/usr --disable-nls
	PATH="$StubDirectory:$PATH" make -j"$(nproc)"
	make DESTDIR="$InstallRoot" install
	rm -rf "$StubDirectory"
}
''')

# strace 6.13 assigns a pointer to const into a non-const one, which this tree
# turns into an error. The one warning is downgraded rather than switching the
# flag off globally, so the change is visible here and does not hide the same
# mistake anywhere else.
Append(
    'strace',
    'strace assigns a const pointer, which this tree makes an error',
    r'''
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
''')

# Anything that links ncurses looks for one of these names, and the recipe
# installs neither: only the wide library and the versioned names are put in
# place. That is why dialog reports "Cannot link ncurses library", procps reports
# "ncurses support missing" and gettext cannot find where the terminfo functions
# come from.
Append(
    'ncurses',
    'install the names and the pkg-config file a build looks for',
    r'''
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
		# The heredoc is unquoted so $Module is substituted, which means the
		# pkg-config variables have to be escaped or the shell expands them and
		# fails on the unbound name.
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
''')

if Failures:
    print('patch-recipes: %d patches did not apply' % Failures, file=sys.stderr)
    sys.exit(1)
print('== done')
PYTHON