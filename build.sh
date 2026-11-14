#!/usr/bin/env sh
# Builds zemu into ./build. Usage: ./build.sh [debug|release|test]
set -e
mode="${1:-release}"
mkdir -p build
case "$mode" in
	debug)   odin build src -out:build/zemu -debug -vet -strict-style ;;
	release) odin build src -out:build/zemu -o:speed -vet -strict-style ;;
	test)
		for pkg in src/systems/nes src/systems/snes src/systems/gb src/systems/gba src/systems/sms src/systems/psx; do
			odin test "$pkg" -vet -strict-style -o:speed
		done
		# interface tests drive the real app headlessly; SDL is not thread-safe
		odin test src -vet -strict-style -define:ODIN_TEST_THREADS=1
		;;
	*) echo "usage: $0 [debug|release|test]"; exit 2 ;;
esac
