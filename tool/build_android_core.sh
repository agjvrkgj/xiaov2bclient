#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
MIHOMO_VERSION="v1.19.30"
ANDROID_API="21"

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required to build the Android Mihomo core." >&2
  exit 1
fi

TASK_NDK_DIRECTORY="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "${TASK_NDK_DIRECTORY}" || ! -d "${TASK_NDK_DIRECTORY}" ]]; then
  echo "Set ANDROID_NDK_HOME to Android NDK 28.0.13004108." >&2
  exit 1
fi

case "$(uname -s)" in
  Linux) TASK_HOST_TAG="linux-x86_64" ;;
  Darwin) TASK_HOST_TAG="darwin-x86_64" ;;
  *)
    echo "Android core builds are supported from Linux or macOS." >&2
    exit 1
    ;;
esac

TASK_TOOLCHAIN="${TASK_NDK_DIRECTORY}/toolchains/llvm/prebuilt/${TASK_HOST_TAG}/bin"
if [[ ! -d "${TASK_TOOLCHAIN}" && "$(uname -s)" == "Darwin" ]]; then
  TASK_HOST_TAG="darwin-arm64"
  TASK_TOOLCHAIN="${TASK_NDK_DIRECTORY}/toolchains/llvm/prebuilt/${TASK_HOST_TAG}/bin"
fi
if [[ ! -d "${TASK_TOOLCHAIN}" ]]; then
  echo "Cannot find the NDK LLVM toolchain under ${TASK_NDK_DIRECTORY}." >&2
  exit 1
fi

build_abi() {
  local abi="$1"
  local goarch="$2"
  local compiler_prefix="$3"
  local output_directory="${PROJECT_DIRECTORY}/android/core/src/main/jniLibs/${abi}"

  mkdir -p "${output_directory}"
  echo "Building Mihomo ${MIHOMO_VERSION} for ${abi}"
  (
    cd "${PROJECT_DIRECTORY}/core"
    CGO_ENABLED=1 \
      GOOS=android \
      GOARCH="${goarch}" \
      CC="${TASK_TOOLCHAIN}/${compiler_prefix}${ANDROID_API}-clang" \
      CXX="${TASK_TOOLCHAIN}/${compiler_prefix}${ANDROID_API}-clang++" \
      go build \
        -tags "with_gvisor,cmfa" \
        -trimpath \
        -buildmode=c-shared \
        -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=${MIHOMO_VERSION}" \
        -o "${output_directory}/libmihomo.so" \
        .
  )
}

(
  cd "${PROJECT_DIRECTORY}/core"
  # main.go is Android-only, so an unqualified download on a Linux host only
  # fetches the direct module. Tidy with all build tags, then download the
  # complete graph before the cross-compiled build runs in read-only mode.
  go mod tidy
  go mod download all
)

build_abi "arm64-v8a" "arm64" "aarch64-linux-android"
build_abi "armeabi-v7a" "arm" "armv7a-linux-androideabi"
build_abi "x86_64" "amd64" "x86_64-linux-android"

echo "Android Mihomo libraries are ready."
