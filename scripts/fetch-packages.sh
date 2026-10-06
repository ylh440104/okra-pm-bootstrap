#!/bin/bash
# fetch-packages.sh - download the bootstrapped x86_64 packages.
#
# These come from the bootstrap run published in
# ylh440104/okra-oaa-packages-x86_64. They are the 70 packages compiled with the
# x86_64-okra-linux-gnu cross toolchain and linked against the Okra glibc, which
# is what makes them usable here: the runner's own compiler would have linked
# them against the runner's glibc instead.
#
# Usage: fetch-packages.sh <destination-dir>
# Environment:
#   GH_TOKEN            token with actions:read on the source repository
#   OKRA_SOURCE_REPOSITORY  default ylh440104/okra-oaa-packages-x86_64
#   OKRA_SOURCE_RELEASE     default okra-userland
# Return: 0 when the archives are all present, 1 otherwise.
set -uo pipefail

Destination="${1:?usage: fetch-packages.sh <destination-dir>}"
SourceRepository="${OKRA_SOURCE_REPOSITORY:-ylh440104/okra-oaa-packages-x86_64}"
SourceRelease="${OKRA_SOURCE_RELEASE:-okra-userland}"
Token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
Expected="${OKRA_EXPECTED_PACKAGES:-70}"

[ -n "$Token" ] || { echo "fetch-packages: GH_TOKEN must be set" >&2; exit 1; }
mkdir -p "$Destination"

echo "== listing the packages in $SourceRelease"
Listing="$(curl -sSL -m 120 \
	-H "Authorization: token $Token" \
	-H 'Accept: application/vnd.github+json' \
	"https://api.github.com/repos/$SourceRepository/releases/tags/$SourceRelease" 2>/dev/null)" || {
	echo "fetch-packages: could not reach the release" >&2
	exit 1
}
printf '%s' "$Listing" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names = [a["name"] for a in data.get("assets", []) if a["name"].endswith(".oaa")]
for name in sorted(names):
    print(name)
' > "$Destination/names.txt"

Count="$(wc -l < "$Destination/names.txt")"
echo "== $Count packages available"
[ "$Count" -ge "$Expected" ] || {
	echo "fetch-packages: expected at least $Expected packages, found $Count" >&2
	exit 1
}

Downloaded=0
while read -r Name; do
	[ -n "$Name" ] || continue
	Target="$Destination/$Name"

	# Every archive has a sidecar checksum in the release, and without checking
	# it a truncated download is only discovered much later as a mysterious
	# unpack failure. The loop retries a few times because the failure is
	# usually transient.
	if [ -s "$Target" ]; then
		Downloaded=$((Downloaded + 1))
		continue
	fi

	Attempt=1
	while [ "$Attempt" -le 3 ]; do
		if curl -fsSL -m 600 -H "Authorization: token $Token" \
			-o "$Target" \
			"https://github.com/$SourceRepository/releases/download/$SourceRelease/$Name" &&
			curl -fsSL -m 60 -H "Authorization: token $Token" \
				-o "$Target.sha256" \
				"https://github.com/$SourceRepository/releases/download/$SourceRelease/$Name.sha256"; then
			Expected="$(awk 'NR == 1 {print $1}' "$Target.sha256" 2>/dev/null || true)"
			Actual="$(sha256sum "$Target" | awk '{print $1}')"
			if [ -n "$Expected" ] && [ "$Expected" = "$Actual" ]; then
				break
			fi
			echo "== $Name failed its checksum on attempt $Attempt, fetching again" >&2
		else
			echo "== $Name could not be fetched on attempt $Attempt" >&2
		fi
		rm -f "$Target" "$Target.sha256"
		Attempt=$((Attempt + 1))
		sleep 5
	done

	[ -s "$Target" ] || {
		echo "fetch-packages: $Name never arrived intact" >&2
		exit 1
	}
	Downloaded=$((Downloaded + 1))
done < "$Destination/names.txt"

echo "== $Downloaded packages in $Destination"
# Every one of them has to be an x86_64 archive, or the layering below would
# silently mix architectures.
Stray="$(find "$Destination" -name '*.oaa' | grep -v '\.x86_64\.' || true)"
[ -z "$Stray" ] || {
	echo "fetch-packages: these archives are not x86_64:" >&2
	echo "$Stray" >&2
	exit 1
}
echo "== every archive is x86_64"
du -sh "$Destination"