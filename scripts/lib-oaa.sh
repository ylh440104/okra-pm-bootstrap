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
