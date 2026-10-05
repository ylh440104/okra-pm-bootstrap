#!/bin/bash
# lib-oaa.sh - read the meta.yaml out of an OAA archive.
#
# The archives are tar files, usually zstd compressed, and Python's tarfile
# cannot read zstd until 3.14. The runners are on 3.12, so the extraction goes
# through the tar command, which handles every compression the archive could
# have been written with.
#
# Source this file; it defines ExtractMeta.

# ExtractMeta() - print the meta.yaml of an archive.
# @Archive: path to the .oaa file.
# Return: 0 and the file contents on standard output, 1 when there is none.
ExtractMeta() {
	local Archive="$1" Member
	for Member in ./meta.yaml meta.yaml; do
		# tar with no compression flag usually sniffs the format; the explicit
		# flags are the fallbacks for the ones it cannot.
		tar -xOf "$Archive" "$Member" 2>/dev/null && return 0
		tar --zstd -xOf "$Archive" "$Member" 2>/dev/null && return 0
		tar -xzf "$Archive" "$Member" 2>/dev/null && return 0
		tar -xJf "$Archive" "$Member" 2>/dev/null && return 0
		tar --lzma -xOf "$Archive" "$Member" 2>/dev/null && return 0
	done
	return 1
}

# ExtractMetaField() - print one scalar field of an archive's meta.yaml.
# @Archive: path to the .oaa file.
# @Field: the key to look up, such as name or version.
# Return: 0 and the value on standard output, 1 when the field is absent.
#
# Only top level scalars are read, so a key inside a list cannot be mistaken
# for one.
ExtractMetaField() {
	local Archive="$1" Field="$2" Meta Value
	Meta="$(ExtractMeta "$Archive")" || return 1
	Value="$(printf '%s\n' "$Meta" | sed -n "s/^${Field}:[[:space:]]*//p" | head -1)"
	Value="${Value%\"}"
	Value="${Value#\"}"
	[ -n "$Value" ] || return 1
	printf '%s' "$Value"
}

# LunarVersion() - rewrite a version the way the resolver will.
# @Raw: the version string from a meta.yaml, such as 1.07.1.
# Return: 0 and the normalised version, 1 when the resolver could not parse it.
#
# The resolver reads three dot separated integers and rebuilds the string from
# them, so a version does not survive the round trip unchanged:
#
#   1.07.1   -> 1.7.1    leading zeros are dropped by std::stoi
#   2.43     -> 2.43.0   a missing component becomes zero
#   1.3-rc1  -> 1.3.0-rc1
#
# The archive is fetched by the name the resolver asks for, so the file has to
# be named after the normalised form rather than the one in the meta.yaml.
LunarVersion() {
	local Raw="$1" Remaining Pre="" Major=0 Minor=0 Patch=0 Index=0 Part
	case "$Raw" in
		*-*) Remaining="${Raw%%-*}"; Pre="${Raw#*-}" ;;
		*)   Remaining="$Raw" ;;
	esac

	local IFS=.
	for Part in $Remaining; do
		# The resolver uses std::stoi, which reads the digits at the front and
		# stops at the first character that is not one, so "2025a" is 2025 and
		# "a2025" is an error. Taking the leading digits reproduces that.
		Digits="${Part%%[!0-9]*}"
		[ -n "$Digits" ] || return 1
		Part=$((10#$Digits))
		case "$Index" in
			0) Major="$Part" ;;
			1) Minor="$Part" ;;
			2) Patch="$Part" ;;
			*) return 1 ;;
		esac
		Index=$((Index + 1))
	done
	[ "$Index" -gt 0 ] || return 1

	if [ -n "$Pre" ]; then
		printf '%s.%s.%s-%s' "$Major" "$Minor" "$Patch" "$Pre"
	else
		printf '%s.%s.%s' "$Major" "$Minor" "$Patch"
	fi
}
