#!/usr/bin/env bash
# Builds libretro cores as Emscripten side modules for the web build and lays
# them out like the buildbot, so the web CORES screen can list and install
# them:
#
#   <out>/.index-extended               "date crc file" per core
#   <out>/info.zip                      the buildbot's core info files
#   <out>/<name>_libretro.wasm.zip
#
# Usage: scripts/build_web_cores.sh [out_dir]   (default build/web/site/cores)
# Needs emsdk (emcc, emmake), git, curl and zip. A core that fails to build is
# skipped.
set -uo pipefail
cd "$(dirname "$0")/.."

out="${1:-build/web/site/cores}"
work=build/web/cores-src
mkdir -p "$out" "$work"
out="$(cd "$out" && pwd)"

# name | repository | makefile | subdirectory
CORES=(
	"2048|libretro/libretro-2048|Makefile.libretro|."
	"fceumm|libretro/libretro-fceumm|Makefile.libretro|."
	"gambatte|libretro/gambatte-libretro|Makefile|."
	"snes9x2010|libretro/snes9x2010|Makefile|."
	"genesis_plus_gx|libretro/Genesis-Plus-GX|Makefile.libretro|."
	"stella2014|libretro/stella2014-libretro|Makefile|."
)

index="$out/.index-extended"
: > "$index"
today="$(date +%F)"

add_core() { # name wasm_path
	local name="$1" wasm="$2"
	cp "$wasm" "$out/${name}_libretro.wasm"
	(cd "$out" && rm -f "${name}_libretro.wasm.zip" && zip -q "${name}_libretro.wasm.zip" "${name}_libretro.wasm" && rm "${name}_libretro.wasm")
	echo "$today 00000000 ${name}_libretro.wasm.zip" >> "$index"
	echo "== built $name"
}

# The frontend's own test core: always there, handy to check that loading works.
emcc -O2 -fPIC -sSIDE_MODULE=1 -o "$work/testcore_libretro.wasm" tests/testcore/testcore.c && \
	add_core testcore "$work/testcore_libretro.wasm"

for entry in "${CORES[@]}"; do
	IFS='|' read -r name repo makefile subdir <<< "$entry"
	echo "== $name"
	dir="$work/$name"
	[ -d "$dir" ] || git clone -q --depth 1 --recursive "https://github.com/$repo" "$dir" || continue
	(
		cd "$dir/$subdir" || exit 1
		# platform=emscripten builds a static archive; -fPIC (through
		# EMCC_CFLAGS, so the core's own CFLAGS are kept) makes it linkable
		# into a side module.
		EMCC_CFLAGS="-fPIC" emmake make -f "$makefile" platform=emscripten -j"$(nproc)"
	) || { echo "!! $name failed to build, skipping"; continue; }
	archive="$(find "$dir" -maxdepth 3 -name "*_libretro_emscripten.*" | head -1)"
	[ -n "$archive" ] || { echo "!! $name produced no archive"; continue; }
	emcc -O2 -sSIDE_MODULE=1 -o "$work/${name}_libretro.wasm" \
		-Wl,--whole-archive "$archive" -Wl,--no-whole-archive \
		|| { echo "!! $name failed to link"; continue; }
	add_core "$name" "$work/${name}_libretro.wasm"
done

# Mirror the core info files: the buildbot doesn't allow cross-origin reads.
curl -fsSL -o "$out/info.zip" https://buildbot.libretro.com/assets/frontend/info.zip

echo "cores in $out:"
cat "$index"
