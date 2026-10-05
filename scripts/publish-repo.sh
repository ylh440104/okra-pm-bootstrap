#!/bin/bash
# publish-repo.sh - turn the bootstrapped packages into a Lunar software source.
#
# The packages that come out of the bootstrap are named for humans:
#
#   make-4.4.1-1.x86_64.bootstrapped.oaa
#
# Lunar looks for artifacts by their package identity instead:
#
#   <namespace>.<name>@<version>.oaa   ->   GNU.make@4.4.1.oaa
#
# so every archive is renamed to what the resolver will ask for. The namespace
# and version are read out of each meta.yaml rather than parsed out of the file
# name, because the two do not always agree.
#
# The synthesized app.glibc package is added here: it is what makes the tree
# installable, since every other package depends on it.
#
# Environment:
#   GH_TOKEN           token with contents:write on the release repository
#   OKRA_OUTPUT        staging directory (default <repo root>/repo)
#   OKRA_ARTIFACTS     extra .oaa files to include (the package manager itself)
#   OKRA_TOOLCHAIN     where the cross toolchain lives
#   OKRA_RELEASE_TAG   release to publish to (default okra-repo)
# Return: 0 when the repository is complete, 1 otherwise.
set -uo pipefail

ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
RepositoryRoot="${OKRA_REPO_ROOT:-$(cd "$ScriptDirectory/.." && pwd)}"
OutputDirectory="${OKRA_OUTPUT:-$RepositoryRoot/repo}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
SourceRepository="${OKRA_SOURCE_REPOSITORY:-ylh440104/okra-oaa-packages-x86_64}"
SourceRelease="${OKRA_SOURCE_RELEASE:-okra-userland}"
Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -n "$Token" ] || { echo "publish-repo: GH_TOKEN must be set" >&2; exit 1; }

# ExtractMetaField, for reading each archive's identity.
. "$ScriptDirectory/lib-oaa.sh"

rm -rf "$OutputDirectory"
mkdir -p "$OutputDirectory/artifacts"

# AddGlibc() - synthesize app.glibc out of the toolchain sysroot.
# Return: 0 when the archive is in the repository.
AddGlibc() {
	if [ -n "${OKRA_GLIBC_ARCHIVE:-}" ] && [ -f "${OKRA_GLIBC_ARCHIVE}" ]; then
		cp -f "$OKRA_GLIBC_ARCHIVE" "$OutputDirectory/artifacts/"
		echo "== added the glibc package from $OKRA_GLIBC_ARCHIVE"
		return 0
	fi
	echo "== synthesizing app.glibc from the toolchain sysroot"
	OKRA_OUTPUT="$OutputDirectory/artifacts" \
		OKRA_TOOLCHAIN="$ToolchainRoot" \
		OKRA_PACKAGE_CACHE="$OutputDirectory/download" \
		GH_TOKEN="$Token" \
		bash "$ScriptDirectory/make-glibc-package.sh" || return 1
	return 0
}

# AddOkrapm() - copy the package manager archive in under its Lunar name.
# Return: 0 when at least one candidate was added.
AddOkrapm() {
	local Added=0 Candidate
	for Candidate in ${OKRA_ARTIFACTS:-} "$RepositoryRoot"/vendor/okrapm/*.oaa; do
		[ -f "$Candidate" ] || continue
		cp -f "$Candidate" "$OutputDirectory/artifacts/"
		echo "== added $Candidate"
		Added=1
	done
	[ "$Added" = "1" ] || echo "== no package manager archive was provided" >&2
	return 0
}

# RenameToLunarNames() - give every human named archive its resolver name.
# Return: 0. Archives whose meta.yaml cannot be read are reported and skipped.
#
# The namespace and version come out of the meta.yaml rather than the file name,
# because the two do not always agree.
RenameToLunarNames() {
	local Archive Namespace Name Version Wanted
	local Renamed=0 Skipped=0
	for Archive in "$OutputDirectory/artifacts"/*.oaa; do
		[ -f "$Archive" ] || continue
		Namespace="$(ExtractMetaField "$Archive" namespace || true)"
		Name="$(ExtractMetaField "$Archive" name || true)"
		Version="$(ExtractMetaField "$Archive" version || true)"
		if [ -z "$Namespace" ] || [ -z "$Name" ] || [ -z "$Version" ]; then
			echo "== cannot read the identity of $(basename "$Archive")" >&2
			Skipped=$((Skipped + 1))
			continue
		fi
		Wanted="$OutputDirectory/artifacts/$Namespace.$Name@$Version.oaa"
		if [ "$Archive" = "$Wanted" ]; then
			continue
		fi
		if [ -e "$Wanted" ]; then
			echo "== $Namespace.$Name@$Version.oaa already exists" >&2
			Skipped=$((Skipped + 1))
			continue
		fi
		mv -f "$Archive" "$Wanted"
		Renamed=$((Renamed + 1))
	done
	echo "== renamed $Renamed archives to their Lunar names"
	[ "$Skipped" -eq 0 ] || echo "== $Skipped archives could not be renamed" >&2
	return 0
}

echo "== collecting the bootstrapped packages"
mkdir -p "$OutputDirectory/download"
Listing="$(curl -sSL -m 120 \
	-H "Authorization: token $Token" \
	-H 'Accept: application/vnd.github+json' \
	"https://api.github.com/repos/$SourceRepository/releases/tags/$SourceRelease" 2>/dev/null)" || {
	echo "publish-repo: could not list the release" >&2
	exit 1
}
printf '%s' "$Listing" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data.get("assets", []):
    if a["name"].endswith(".oaa"):
        print(a["name"])
' > "$OutputDirectory/download/names.txt"

PackageCount="$(wc -l < "$OutputDirectory/download/names.txt")"
echo "== $PackageCount packages to fetch"
[ "$PackageCount" -gt 50 ] || { echo "publish-repo: too few packages" >&2; exit 1; }

while read -r Name; do
	[ -n "$Name" ] || continue
	curl -sSL -m 600 -H "Authorization: token $Token" \
		-o "$OutputDirectory/artifacts/$Name" \
		"https://github.com/$SourceRepository/releases/download/$SourceRelease/$Name" || {
		echo "publish-repo: could not download $Name" >&2
		exit 1
	}
done < "$OutputDirectory/download/names.txt"

AddGlibc || exit 1
AddOkrapm
RenameToLunarNames

echo "== repository contents"
ls "$OutputDirectory/artifacts" | wc -l
ls "$OutputDirectory/artifacts" | head -8

echo "== building the index"
python3 -c "
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('repo_server', '$ScriptDirectory/repo-server.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print('== wrote', module.write_index(Path('$OutputDirectory')))
"

IndexedCount="$(grep -c '^name:' "$OutputDirectory/index.yaml" || true)"
echo "== the index lists $IndexedCount packages"
[ "$IndexedCount" -gt 50 ] || { echo "publish-repo: the index is too small" >&2; exit 1; }

rm -rf "$OutputDirectory/download"
echo "== done"
du -sh "$OutputDirectory"
ls -la "$OutputDirectory"