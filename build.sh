#!/usr/bin/env bash
# Build script for ZEMU.  Usage: ./build.sh [desktop|run|release] [args...]
set -euo pipefail
cd "$(dirname "$0")"

target="${1:-desktop}"; shift || true
mkdir -p build

case "$target" in
	desktop)
		odin build src -out:build/zemu -debug
		;;
	release)
		odin build src -out:build/zemu -o:speed -no-bounds-check
		;;
	run)
		odin build src -out:build/zemu -debug && ./build/zemu "$@"
		;;
	*)
		echo "unknown target: $target" >&2; exit 1
		;;
esac
