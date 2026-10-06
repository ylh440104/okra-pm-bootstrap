#!/bin/bash
# rename-to-lunar.sh - give human named archives the names the resolver asks for.
#
# A build produces:
#
#   make-4.4.1-1.x86_64.bootstrapped.oaa
#
# and lunar looks for artifacts by package identity:
#
#   <namespace>.<name>@<version>.oaa   ->   GNU.make@4.4.1.oaa
#
# The namespace and the version are read out of each meta.yaml rather than
# parsed from the file name, because the two do not always agree, and the
# version is put through LunarVersion because the resolver rebuilds it from
# three integers.
#
# The sidecar checksum is renamed with its archive. Left behind under the old
# name it is unreachable rather than absent, and anything verifying a download
# looks for it beside the archive.
#
# Usage: rename-to-lunar.sh <directory>
# Return: 0 when every archive was either already named correctly or renamed,
#         1 when one could not be read.
set -uo pipefail

Directory="${1:?usage: rename-to-lunar.sh <directory>}"
ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"

[ -d "$Directory" ] || { echo "rename-to-lunar: no directory at $Directory" >&2; exit 1; }

# ExtractMetaField and LunarVersion, for reading each archive's identity.
. "$ScriptDirectory/lib-oaa.sh"

Renamed=0
Skipped=0
for Archive in "$Directory"/*.oaa; do
	[ -f "$Archive" ] || continue
	Namespace="$(ExtractMetaField "$Archive" namespace || true)"
	Name="$(ExtractMetaField "$Archive" name || true)"
	Version="$(ExtractMetaField "$Archive" version || true)"
	if [ -z "$Namespace" ] || [ -z "$Name" ] || [ -z "$Version" ]; then
		echo "== cannot read the identity of $(basename "$Archive")" >&2
		Skipped=$((Skipped + 1))
		continue
	fi
	if ! Version="$(LunarVersion "$Version")"; then
		echo "== the resolver cannot parse the version of $(basename "$Archive")" >&2
		Skipped=$((Skipped + 1))
		continue
	fi
	Wanted="$Directory/$Namespace.$Name@$Version.oaa"
	if [ "$Archive" = "$Wanted" ]; then
		continue
	fi
	if [ -e "$Wanted" ]; then
		# Two archives claiming one identity is a mistake worth reporting: the
		# caller would otherwise lose one of them without being told.
		echo "== $Namespace.$Name@$Version.oaa already exists" >&2
		Skipped=$((Skipped + 1))
		continue
	fi
	[ -f "$Archive.sha256" ] && mv -f "$Archive.sha256" "$Wanted.sha256"
	mv -f "$Archive" "$Wanted"
	Renamed=$((Renamed + 1))
done

echo "== renamed $Renamed archives to the names the resolver asks for"
[ "$Skipped" -eq 0 ] || echo "== $Skipped archives could not be renamed" >&2
return_status=0
[ "$Skipped" -eq 0 ] || return_status=1
exit "$return_status"