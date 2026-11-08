#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="ios"
JOBS="4"
SOURCE_CACHE="$ROOT/Native/.sources"
BUILD_ROOT="$ROOT/Native/.build"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --source-cache) SOURCE_CACHE="$2"; shift 2 ;;
        --build-root) BUILD_ROOT="$2"; shift 2 ;;
        --help)
            printf '%s\n' "Usage: $0 [--platform ios|linux] [--jobs 4] [--source-cache PATH] [--build-root PATH]"
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid job count\n' >&2; exit 2; }
[[ "$PLATFORM" == ios || "$PLATFORM" == linux ]] || { printf 'Platform must be ios or linux\n' >&2; exit 2; }
for command in cmake git python3; do
    command -v "$command" >/dev/null || { printf 'Install missing build tool: %s\n' "$command" >&2; exit 1; }
done
if [[ "$PLATFORM" == ios ]]; then
    [[ "$(uname -s)" == Darwin ]] || { printf 'iOS frameworks require macOS and full Xcode. Linux can run --platform linux.\n' >&2; exit 1; }
    xcodebuild -version >/dev/null
    xcrun --sdk iphoneos --find clang >/dev/null
fi
mkdir -p "$SOURCE_CACHE" "$BUILD_ROOT" "$ROOT/Native/Artifacts"
SOURCE_CACHE="$(cd "$SOURCE_CACHE" && pwd)"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
for engine in whisper llama; do
    repository="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["repository"])' "$ROOT/Native/upstream-lock.json" "$engine")"
    commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["commit"])' "$ROOT/Native/upstream-lock.json" "$engine")"
    source="$SOURCE_CACHE/$engine"
    if [[ ! -e "$source" ]]; then
        git init -q "$source"
        git -C "$source" remote add origin "$repository"
        git -C "$source" fetch --depth 1 origin "$commit"
        git -C "$source" checkout --detach -q FETCH_HEAD
    fi
    actual="$(git -C "$source" rev-parse HEAD)"
    [[ "$actual" == "$commit" ]] || { printf 'Source revision mismatch for %s: expected %s\n' "$engine" "$commit" >&2; exit 1; }
    [[ -z "$(git -C "$source" status --porcelain --untracked-files=no)" ]] || { printf 'Pinned source has local modifications: %s\n' "$source" >&2; exit 1; }
    if [[ "$engine" == whisper ]]; then framework=AOWhisper; else framework=AOLlama; fi
    if [[ "$PLATFORM" == linux ]]; then
        directory="$BUILD_ROOT/$engine-linux"
        cmake -S "$ROOT/Native" -B "$directory" -DAO_ENGINE="$engine" -DAO_ENGINE_SOURCE="$source" -DCMAKE_BUILD_TYPE=Release
        cmake --build "$directory" --target "$framework" --parallel "$JOBS"
        if [[ "$engine" == whisper ]]; then
            cmake --build "$directory" --target ao_json_escape_test --parallel "$JOBS"
            "$directory/ao_json_escape_test"
        else
            cmake --build "$directory" --target ao_json_grammar_test --parallel "$JOBS"
            "$directory/ao_json_grammar_test"
        fi
    else
        for sdk in iphoneos iphonesimulator; do
            architecture=arm64
            [[ "$sdk" != iphonesimulator ]] || architecture='arm64;x86_64'
            directory="$BUILD_ROOT/$engine-$sdk"
            cmake -S "$ROOT/Native" -B "$directory" -DAO_ENGINE="$engine" -DAO_ENGINE_SOURCE="$source" \
                -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
            cmake --build "$directory" --target "$framework" --config Release --parallel "$JOBS"
        done
        output="$ROOT/Native/Artifacts/$framework.xcframework"
        if [[ -e "$output" ]]; then
            printf 'Existing artifact would be replaced; move it aside first: %s\n' "$output" >&2
            exit 1
        fi
        xcodebuild -create-xcframework \
            -framework "$BUILD_ROOT/$engine-iphoneos/$framework.framework" \
            -framework "$BUILD_ROOT/$engine-iphonesimulator/$framework.framework" -output "$output"
    fi
done
if [[ "$PLATFORM" == linux ]]; then
    python3 "$ROOT/Native/Tests/test_bridges.py" --build-root "$BUILD_ROOT"
else
    python3 "$ROOT/tools/generate_project.py"
    printf 'XCFrameworks ready in %s/Native/Artifacts\n' "$ROOT"
fi
