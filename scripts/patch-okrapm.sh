#!/bin/bash
# patch-okrapm.sh - fix how the package manager turns payload paths into targets.
#
# Three places walk a directory and work out where each entry goes by taking its
# path relative to the root it came from, using fs::relative. That function
# resolves symlinks, so for any package whose libraries are a chain of links the
# answer is wrong for every link:
#
#   libncursesw.so.6.5   the real file
#   libncursesw.so.6  -> libncursesw.so.6.5
#   libtinfo.so.6     -> libncursesw.so.6
#
#   fs::relative(".../libncursesw.so.6", root) = "usr/lib/libncursesw.so.6.5"
#   fs::relative(".../libtinfo.so.6",    root) = "usr/lib/libncursesw.so.6.5"
#
# So the install writes the real file twice, replacing it with a symlink that
# points at itself, and never creates the two names anything actually links
# against. bash then cannot find libtinfo.so.6 and the system does not start.
#
# lexically_relative does the same path arithmetic without asking the filesystem,
# which is what these call sites want.
#
# The patch is applied here because this repository cannot push to Okrapm. It
# fails if a pattern has gone, so an upstream change cannot quietly leave the
# bug in place.
#
# Usage: patch-okrapm.sh <okrapm-checkout>
# Return: 0 when every site is patched, 1 otherwise.
set -uo pipefail

Checkout="${1:?usage: patch-okrapm.sh <okrapm-checkout>}"
[ -d "$Checkout" ] || { echo "patch-okrapm: no checkout at $Checkout" >&2; exit 1; }

# Patch() - replace one call site and report what happened.
# @File: path relative to the checkout.
# @Expected: how many occurrences the file must contain.
# @From: the text to replace, as a basic regular expression.
# @To: what to replace it with.
# Return: 0 when the count matches and the replacement was made, 1 otherwise.
Patch() {
	local File="$Checkout/$1" Expected="$2" From="$3" To="$4" Found
	[ -f "$File" ] || { echo "patch-okrapm: no $1" >&2; return 1; }
	Found="$(grep -c "$From" "$File" || true)"
	if [ "$Found" -eq 0 ]; then
		echo "patch-okrapm: $1 no longer contains the pattern, so it may be fixed upstream" >&2
		echo "               looking for: $From" >&2
		return 1
	fi
	if [ "$Found" -ne "$Expected" ]; then
		echo "patch-okrapm: $1 has $Found of the pattern, expected $Expected" >&2
		return 1
	fi
	sed -i "s|$From|$To|g" "$File"
	echo "== patched $Found site(s) in $1"
	return 0
}

echo "== fixing the symlink handling in the package manager sources"

# The install path: copy_payload, which is what broke the ncurses package.
Patch "lib/okrapmlib/src/lunar_core.cpp" 1 \
	'auto rel = fs::relative(entry.path(), payload, ec);' \
	'auto rel = entry.path().lexically_relative(payload);' || exit 1

# OPSIS installing a payload directory, and OPSIS packing one: the same line
# appears in both, and both have the same problem.
Patch "opsis/src/engine.cpp" 2 \
	'fs::path Rel = fs::relative(It->path(), From, Error);' \
	'fs::path Rel = It->path().lexically_relative(From);' || exit 1

# Nothing may be left behind: a missed call site is the same bug in a different
# corner, and it would be found much later.
Left="$(grep -rn 'fs::relative' "$Checkout/lib" "$Checkout/src" "$Checkout/opsis" 2>/dev/null || true)"
[ -z "$Left" ] || {
	echo "patch-okrapm: fs::relative is still used here:" >&2
	echo "$Left" >&2
	exit 1
}
echo "== no fs::relative calls remain"

# Show the result, so the log carries the evidence rather than the claim.
echo "== what the patched lines look like now"
grep -n 'lexically_relative' "$Checkout/lib/okrapmlib/src/lunar_core.cpp" \
	"$Checkout/opsis/src/engine.cpp" | sed 's/^/   /'
echo "== done"