#!/usr/bin/env bash
# Build script for ZEMU.
#
#   ./build.sh desktop        debug build        -> build/zemu
#   ./build.sh release        optimized build    -> build/zemu
#   ./build.sh run [args]     build and run
#   ./build.sh android        APK                -> build/zemu.apk
#
# Android needs ANDROID_HOME (SDK with build-tools and a platform),
# ANDROID_NDK_HOME (NDK r30+), a JDK, cmake and ninja. ZEMU_ANDROID_ABIS picks
# the ABIs (default "arm64-v8a"; add x86_64 for the emulator).
set -euo pipefail
cd "$(dirname "$0")"

target="${1:-desktop}"; shift || true
mkdir -p build

SDL_VERSION="3.4.18"
SDL_DIR="third_party/SDL3-$SDL_VERSION"

fetch_sdl() {
	if [ ! -d "$SDL_DIR" ]; then
		mkdir -p third_party
		echo "fetching SDL $SDL_VERSION source"
		curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL3-$SDL_VERSION.tar.gz" \
			| tar -xz -C third_party
	fi
}

build_android() {
	: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
	: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
	local api=29
	local platform
	platform="$(ls -d "$ANDROID_HOME"/platforms/android-* | sort -V | tail -1)"
	local tools
	tools="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
	local jar="$platform/android.jar"
	local out=build/android
	local abis="${ZEMU_ANDROID_ABIS:-arm64-v8a}"
	fetch_sdl
	rm -rf "$out/apk"
	mkdir -p "$out/apk/lib"

	for abi in $abis; do
		local odin_target
		case "$abi" in
			arm64-v8a)   odin_target=linux_arm64 ;;
			armeabi-v7a) odin_target=linux_arm32 ;;
			x86_64)      odin_target=linux_amd64 ;;
			x86)         odin_target=linux_i386 ;;
			*) echo "unknown ABI $abi" >&2; exit 1 ;;
		esac

		# SDL3 shared library for this ABI.
		local sdl_build="$out/sdl-$abi"
		if [ ! -f "$sdl_build/libSDL3.so" ]; then
			cmake -S "$SDL_DIR" -B "$sdl_build" -G Ninja \
				-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
				-DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$api" \
				-DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF \
				-DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
			cmake --build "$sdl_build"
		fi

		mkdir -p "$out/apk/lib/$abi"
		"$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip --strip-unneeded \
			-o "$out/apk/lib/$abi/libSDL3.so" "$sdl_build/libSDL3.so"
		ODIN_ANDROID_NDK="$ANDROID_NDK_HOME" odin build src \
			-target:"$odin_target" -subtarget:android -minimum-os-version:$api \
			-build-mode:shared -o:speed \
			-extra-linker-flags:"-L$PWD/$sdl_build" \
			-out:"$out/apk/lib/$abi/libmain.so"
	done

	# Java: SDL's activity classes plus ours, compiled to dex.
	rm -rf "$out/classes" && mkdir -p "$out/classes"
	javac --release 11 -nowarn -classpath "$jar" -d "$out/classes" \
		$(find "$SDL_DIR/android-project/app/src/main/java" -name '*.java') \
		$(find android/java -name '*.java')
	(cd "$out/classes" && jar cf ../classes.jar .)
	"$tools/d8" --release --min-api $api --lib "$jar" --output "$out/apk" "$out/classes.jar"

	# Resources and manifest, then add code and libraries, align and sign.
	"$tools/aapt2" compile --dir android/res -o "$out/res.zip"
	"$tools/aapt2" link -o "$out/unsigned.apk" -I "$jar" \
		--manifest android/AndroidManifest.xml \
		--min-sdk-version $api --target-sdk-version "${platform##*-}" \
		--version-code 1 --version-name "0.1" \
		"$out/res.zip"
	(cd "$out/apk" && zip -qr ../unsigned.apk classes.dex lib)
	"$tools/zipalign" -f -p 4 "$out/unsigned.apk" "$out/aligned.apk"

	local ks="${ZEMU_KEYSTORE:-$HOME/.android/debug.keystore}"
	local ks_pass="${ZEMU_KEYSTORE_PASS:-android}"
	if [ ! -f "$ks" ]; then
		ks="$out/debug.keystore"
		[ -f "$ks" ] || keytool -genkeypair -keystore "$ks" -storepass android -keypass android \
			-alias androiddebugkey -keyalg RSA -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
	fi
	"$tools/apksigner" sign --ks "$ks" --ks-pass "pass:$ks_pass" --out build/zemu.apk "$out/aligned.apk"
	echo "built build/zemu.apk"
}

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
	android)
		build_android
		;;
	*)
		echo "unknown target: $target" >&2; exit 1
		;;
esac
