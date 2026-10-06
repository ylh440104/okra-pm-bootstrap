#!/bin/bash
# make-sample-package.sh - build a package that is in the repository and not in
# the userland.
#
# The verification needs something to install from inside the chroot. Every
# package in the index is already installed by the first transaction, so the
# repository gets one more: a small program built with the same cross toolchain
# that built everything else, packed with the same opsis.
#
# It is built statically so it does not depend on which libc ends up under it,
# which keeps the test about the package manager rather than about the library
# search path.
#
# Usage: make-sample-package.sh <opsis-binary> <output-dir>
# Environment:
#   OKRA_TOOLCHAIN  holds cross/ (default /opt/okra-toolchain)
# Return: 0 when the archive and its checksum exist, 1 otherwise.
set -uo pipefail

Opsis="${1:?usage: make-sample-package.sh <opsis-binary> <output-dir>}"
OutputDirectory="${2:?usage: make-sample-package.sh <opsis-binary> <output-dir>}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
TargetTriple="${OKRA_TARGET_TRIPLE:-x86_64-okra-linux-gnu}"
ScratchDirectory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-sample"

CrossGcc="$ToolchainRoot/cross/bin/$TargetTriple-gcc"
[ -x "$CrossGcc" ] || { echo "make-sample-package: no cross gcc at $CrossGcc" >&2; exit 1; }
[ -x "$Opsis" ] || { echo "make-sample-package: no opsis at $Opsis" >&2; exit 1; }

rm -rf "$ScratchDirectory"
mkdir -p "$ScratchDirectory/stage" "$OutputDirectory"

# A program that says what it is, so the run can show it was executed rather
# than just that a file appeared.
cat > "$ScratchDirectory/hello.c" <<'EOF'
#include <stdio.h>

int main(void)
{
	printf("hello from the Okra package manager\n");
	return 0;
}
EOF

echo "== compiling the sample with the cross toolchain"
"$CrossGcc" -static -O2 -o "$ScratchDirectory/hello" "$ScratchDirectory/hello.c" || {
	echo "make-sample-package: the cross compiler failed" >&2
	exit 1
}
file "$ScratchDirectory/hello"

mkdir -p "$ScratchDirectory/stage"
cp "$ScratchDirectory/hello" "$ScratchDirectory/stage/hello"

# The same direct package form the package manager itself is packed with.
cat > "$ScratchDirectory/hello.opsis" <<'OPSIS'
public class Package {
	public int MAIN(BuildContext ctx) {
		BeginPackage();
		PackFile(Environment("SAMPLE_BIN"), "/usr/bin/hello", "0755");
		FinishPackage();
		return 0;
	}
}
OPSIS

echo "== packing it with opsis"
OPSIS_PKG_NAMESPACE=Okra \
OPSIS_PKG_NAME=hello \
OPSIS_PKG_VERSION=1.0.0 \
OPSIS_PKG_DESCRIPTION="Sample package for the scheme B verification" \
OPSIS_PKG_OUTPUT="$OutputDirectory/Okra.hello@1.0.0.oaa" \
OPSIS_BUILD_DIR="$ScratchDirectory/stage" \
SAMPLE_BIN="$ScratchDirectory/stage/hello" \
OPSIS_ALLOW_NONROOT=1 \
"$Opsis" pack --allow-nonroot "$ScratchDirectory/hello.opsis" || {
	echo "make-sample-package: opsis pack failed" >&2
	exit 1
}

Archive="$OutputDirectory/Okra.hello@1.0.0.oaa"
[ -f "$Archive" ] || { echo "make-sample-package: no archive was produced" >&2; exit 1; }
sha256sum "$Archive" | awk '{print $1"  Okra.hello@1.0.0.oaa"}' > "$Archive.sha256"

echo "== the sample package"
ls -la "$OutputDirectory"
echo "== what it declares"
tar -xOf "$Archive" ./meta.yaml 2>/dev/null || tar --zstd -xOf "$Archive" ./meta.yaml 2>/dev/null || true