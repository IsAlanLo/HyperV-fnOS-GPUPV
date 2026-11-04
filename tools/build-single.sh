#!/usr/bin/env bash
# tools/build-single.sh - assemble gpupv-fnos.sh (the ONE file you copy to the NAS)
# from the modular lib/*.sh.
#
# Why generate it: the modular tree is what gets edited and tested, but what a
# user copies to a NAS should be a single file with no relative imports - one
# scp/wget and it runs, even from /tmp. GPUPV_DEV=1 keeps the modular version in
# ./gpupv.sh usable at the same time; both run the same code.
#
#   bash tools/build-single.sh     # regenerate gpupv-fnos.sh after editing lib/
set -eu
cd "$(dirname "$0")/.."
REPO=$(pwd)
OUT="$REPO/gpupv-fnos.sh"
LIBS="common assets deps triage verify doctor module driverstore loaders service serve"

tmp=$(mktemp)
{
	# shebang + the file comment + `set -u`
	sed -n '1,/^set -u$/p' gpupv.sh | sed 's/^# gpupv\.sh - /# gpupv-fnos.sh - /'
	echo
	echo '# ---------------------------------------------------------------------'
	echo '# GENERATED FILE - do not edit. Source of truth: gpupv.sh + lib/*.sh.'
	echo '# Rebuild with:  bash tools/build-single.sh'
	echo '# ---------------------------------------------------------------------'
	echo
	echo 'SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)'
	echo

	for m in $LIBS; do
		printf '\n# ====================== lib/%s.sh ======================\n' "$m"
		# drop the shebang and the leading comment banner of each module
		awk 'NR==1 && /^#!/ {next} NR==1 && /^#/ {next} /^$/{if(!seen) next} {seen=1; print}' "lib/$m.sh"
	done

	printf '\n# ====================== dispatch ======================\n'
	sed -n '/^usage() {/,$p' gpupv.sh
} > "$tmp"
mv "$tmp" "$OUT"
chmod +x "$OUT"
bash -n "$OUT" || { echo "!! generated file has a syntax error" >&2; exit 1; }
printf 'built %s (%s lines, %s bytes)\n' "${OUT#$REPO/}" "$(wc -l < "$OUT")" "$(stat -c%s "$OUT")"
