#!/bin/bash
# fetch-toolchain.sh - get the x86_64-okra-linux-gnu cross toolchain.
#
# The toolchain is the seed of everything here: it is what turns a Ubuntu
# runner into something that can produce Okra binaries. Building it takes about
# half an hour, so it is fetched from the artifacts published by
# ylh440104/okra-oaa-packages-x86_64 and cached between runs by the caller.
#
# Layout after this script succeeds, under OKRA_TOOLCHAIN (default
# /opt/okra-toolchain):
#
#   cross/bin/x86_64-okra-linux-gnu-gcc    the cross compiler
#   okra-sysroot/                          the Okra glibc and headers
#
# Environment:
#   GH_TOKEN            token with actions:read on the source repository
#   OKRA_TOOLCHAIN      where to unpack it (default /opt/okra-toolchain)
#   OKRA_TARGET_TRIPLE  target triple (default x86_64-okra-linux-gnu)
#   OKRA_TOOLCHAIN_SOURCE_REPOSITORY  default ylh440104/okra-oaa-packages-x86_64
# Return: 0 when a usable toolchain is in place, 1 otherwise.
set -uo pipefail

Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
TargetTriple="${OKRA_TARGET_TRIPLE:-x86_64-okra-linux-gnu}"
SourceRepository="${OKRA_TOOLCHAIN_SOURCE_REPOSITORY:-ylh440104/okra-oaa-packages-x86_64}"
ScratchDirectory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

[ -n "$Token" ] || { echo "fetch-toolchain: GH_TOKEN must be set" >&2; exit 1; }

# CrossGcc() - path of the cross compiler this script is about.
# Return: the path, whether or not it exists.
CrossGcc() {
echo "$ToolchainRoot/cross/bin/$TargetTriple-gcc"
}

# ToolchainIsUsable() - check the two files every later step depends on.
# Return: 0 when the compiler runs and the sysroot loader is there.
ToolchainIsUsable() {
local Gcc
Gcc="$(CrossGcc)"
[ -x "$Gcc" ] || return 1
[ -f "$ToolchainRoot/okra-sysroot/lib64/ld-linux-x86-64.so.2" ] || return 1
"$Gcc" --version >/dev/null 2>&1 || return 1
return 0
}

if ToolchainIsUsable; then
echo "== the cross toolchain is already in place at $ToolchainRoot"
"$(CrossGcc)" --version | head -1
exit 0
fi

echo "== looking for a published cross toolchain"

# FindArtifacts() - list the cross toolchain artifacts, newest first.
# Return: 0 on a successful API call, 1 otherwise. Prints
#         "<artifact id> <run id> <size>" lines.
FindArtifacts() {
local Page Response
for Page in 1 2 3; do
Response="$(curl -sSL -m 60 \
-H "Authorization: token $Token" \
-H 'Accept: application/vnd.github+json' \
"https://api.github.com/repos/$SourceRepository/actions/artifacts?name=okra-cross-toolchain&per_page=100&page=$Page" 2>/dev/null)" || return 1
printf '%s' "$Response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# An error response parses as JSON too, so checking for the list alone would
# report a permission problem or a rate limit as "nothing published". That is
# how an expired cache came to look like an empty repository.
if "message" in data:
    print(data["message"], file=sys.stderr)
    sys.exit(1)
for a in data.get("artifacts", []):
    if a.get("expired"):
        continue
    print(a["id"], a.get("workflow_run", {}).get("id", 0), a.get("size_in_bytes", 0))
' || return 1
done
return 0
}

Artifacts="$(FindArtifacts)" || { echo "== could not query the artifacts" >&2; exit 1; }
if [ -z "$Artifacts" ]; then
echo "== no published cross toolchain is available" >&2
exit 1
fi

echo "== published cross toolchains:"
printf '%s\n' "$Artifacts" | head -5 | while read -r Id RunId Size; do
printf '   artifact %s from run %s (%s bytes)\n' "$Id" "$RunId" "$Size"
done

while read -r ArtifactId RunId Size; do
[ -n "${ArtifactId:-}" ] || continue
Archive="$ScratchDirectory/okra-cross-toolchain.zip"
echo "== downloading the cross toolchain artifact $ArtifactId from run $RunId"
if ! curl -sSL --retry 3 -m 1200 \
-H "Authorization: token $Token" \
-H 'Accept: application/vnd.github+json' \
-o "$Archive" \
"https://api.github.com/repos/$SourceRepository/actions/artifacts/$ArtifactId/zip"; then
echo "== the download failed" >&2
continue
fi

Unpacked="$ScratchDirectory/okra-cross-toolchain"
rm -rf "$Unpacked"
mkdir -p "$Unpacked"
if ! unzip -qo "$Archive" -d "$Unpacked"; then
echo "== the artifact is not a readable archive" >&2
continue
fi
rm -f "$Archive"

Tarball="$(find "$Unpacked" -maxdepth 1 -name '*.tar.zst' -print -quit)"
if [ -z "$Tarball" ]; then
echo "== the artifact holds no toolchain tarball" >&2
continue
fi

Checksum="$Tarball.sha256"
if [ -f "$Checksum" ]; then
Expected="$(awk '{print $1}' "$Checksum")"
Actual="$(sha256sum "$Tarball" | awk '{print $1}')"
if [ "$Expected" != "$Actual" ]; then
echo "== the toolchain checksum does not match" >&2
continue
fi
echo "== the toolchain checksum matches"
fi

sudo mkdir -p "$(dirname "$ToolchainRoot")"
sudo rm -rf "$ToolchainRoot"
sudo tar --zstd -xf "$Tarball" -C "$(dirname "$ToolchainRoot")"
sudo chown -R "$(id -u):$(id -g)" "$ToolchainRoot"
rm -rf "$Unpacked"

if ToolchainIsUsable; then
echo "== the cross toolchain from run $RunId is in place"
"$(CrossGcc)" --version | head -1
exit 0
fi
echo "== that artifact did not produce a usable toolchain" >&2
done <<< "$Artifacts"

# The artifact is a cache with a 14 day life, so it is expected to be gone most
# of the time. The same tarball is published as a release asset, which does not
# expire: without this the chain stops working two weeks after the last run and
# says the repository has nothing, which is not what happened.
ReleaseTag="${OKRA_TOOLCHAIN_RELEASE:-cross-toolchain}"
ReleaseBase="https://github.com/$SourceRepository/releases/download/$ReleaseTag"
echo "== looking for the seed in the $ReleaseTag release"
Archive="$ScratchDirectory/okra-cross-toolchain.tar.zst"
ArchiveSum="$Archive.sha256"
if curl -fsSL --retry 3 -m 1200 -H "Authorization: token $Token" \
	-o "$Archive" "$ReleaseBase/okra-cross-toolchain.tar.zst" &&
	curl -fsSL --retry 3 -m 1200 -H "Authorization: token $Token" \
	-o "$ArchiveSum" "$ReleaseBase/okra-cross-toolchain.tar.zst.sha256"; then
	Expected="$(awk '{print $1}' "$ArchiveSum")"
	Actual="$(sha256sum "$Archive" | awk '{print $1}')"
	if [ "$Expected" != "$Actual" ]; then
		echo "== the published toolchain checksum does not match" >&2
	else
		sudo mkdir -p "$(dirname "$ToolchainRoot")"
		sudo rm -rf "$ToolchainRoot"
		if sudo tar --zstd -xf "$Archive" -C "$(dirname "$ToolchainRoot")" &&
			sudo chown -R "$(id -u):$(id -g)" "$ToolchainRoot" &&
			ToolchainIsUsable; then
			echo "== the cross toolchain from the $ReleaseTag release is in place"
			"$(CrossGcc)" --version | head -1
			exit 0
		fi
		echo "== the published toolchain did not unpack into a usable one" >&2
	fi
else
	echo "== the $ReleaseTag release does not have the toolchain either" >&2
fi

echo "== no usable cross toolchain could be fetched" >&2
echo "   rebuild it with: gh workflow run bootstrap-toolchain.yml -f rebuild_toolchain=true" >&2
exit 1
