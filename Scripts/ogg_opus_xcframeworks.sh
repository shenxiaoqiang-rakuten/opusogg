#!/usr/bin/env bash
# Aggregate Target「OggOpusXCFrameworks」：与 OpusOGG 分开执行，避免与 ProcessXCFramework 形成依赖环。
# 若尚未生成 XCFramework，则从 Xiph 镜像下载源码，交叉编译并打包为：
#   OpusOGG/Frameworks/libogg.xcframework
#   OpusOGG/Frameworks/libopus.xcframework
# 依赖：Xcode 命令行工具、curl、make。
set -euo pipefail

LIBOGG_VERSION="${LIBOGG_VERSION:-1.3.6}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"

OGG_BASE_URL="https://downloads.xiph.org/releases/ogg"
OPUS_BASE_URL="https://downloads.xiph.org/releases/opus"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SRCROOT:-}" ]]; then
  SRCROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
OPT_FLAGS="-Os"
if [[ "${CONFIGURATION}" == "Debug" ]]; then
  OPT_FLAGS="-O0 -g"
fi

VENDOR="${SRCROOT}/Vendor"
SRC_CACHE="${VENDOR}/src"
BUILD_ROOT="${VENDOR}/build"
OUT_DIR="${SRCROOT}/OpusOGG/Frameworks"
# Stamp lives under Vendor/ so it is not picked up by the OpusOGG target’s file-system sync into the framework bundle.
STAMP="${VENDOR}/.stamp-libogg-${LIBOGG_VERSION}-libopus-${OPUS_VERSION}"
LEGACY_STAMP="${OUT_DIR}/.built-libogg-${LIBOGG_VERSION}-libopus-${OPUS_VERSION}"

mkdir -p "${SRC_CACHE}" "${BUILD_ROOT}" "${OUT_DIR}"

if [[ ! -f "${STAMP}" ]] && [[ -f "${LEGACY_STAMP}" ]] \
  && [[ -d "${OUT_DIR}/libogg.xcframework" ]] \
  && [[ -d "${OUT_DIR}/libopus.xcframework" ]]; then
  touch "${STAMP}"
fi

if [[ -f "${STAMP}" ]] \
  && [[ -d "${OUT_DIR}/libogg.xcframework" ]] \
  && [[ -d "${OUT_DIR}/libopus.xcframework" ]]; then
  echo "XCFramework 已存在: ${OUT_DIR}"
  exit 0
fi

download_if_needed() {
  local url="$1"
  local dest="$2"
  if [[ ! -f "${dest}" ]]; then
    echo "下载: ${url}"
    curl -L --fail --retry 3 --connect-timeout 30 -o "${dest}" "${url}"
  fi
}

OGG_TAR="${SRC_CACHE}/libogg-${LIBOGG_VERSION}.tar.gz"
OPUS_TAR="${SRC_CACHE}/opus-${OPUS_VERSION}.tar.gz"
download_if_needed "${OGG_BASE_URL}/libogg-${LIBOGG_VERSION}.tar.gz" "${OGG_TAR}"
download_if_needed "${OPUS_BASE_URL}/opus-${OPUS_VERSION}.tar.gz" "${OPUS_TAR}"

OGG_SRC="${SRC_CACHE}/libogg-${LIBOGG_VERSION}"
OPUS_SRC="${SRC_CACHE}/opus-${OPUS_VERSION}"

if [[ ! -d "${OGG_SRC}" ]]; then
  tar -xzf "${OGG_TAR}" -C "${SRC_CACHE}"
fi
if [[ ! -d "${OPUS_SRC}" ]]; then
  tar -xzf "${OPUS_TAR}" -C "${SRC_CACHE}"
fi

cflags_for_sdk() {
  local sdk_name="$1"
  local sdkroot="$2"
  if [[ "${sdk_name}" == "iphonesimulator" ]]; then
    echo "-isysroot ${sdkroot} -mios-simulator-version-min=${MIN_IOS} ${OPT_FLAGS}"
  else
    echo "-isysroot ${sdkroot} -miphoneos-version-min=${MIN_IOS} ${OPT_FLAGS}"
  fi
}

ldflags_for_sdk() {
  local sdk_name="$1"
  local sdkroot="$2"
  if [[ "${sdk_name}" == "iphonesimulator" ]]; then
    echo "-isysroot ${sdkroot} -mios-simulator-version-min=${MIN_IOS}"
  else
    echo "-isysroot ${sdkroot} -miphoneos-version-min=${MIN_IOS}"
  fi
}

build_ogg_opus_for_prefix() {
  local sdk_name="$1"
  local arch="$2"
  local host="$3"
  local prefix="$4"

  local sdkroot
  sdkroot="$(xcrun --sdk "${sdk_name}" --show-sdk-path)"
  local cc="xcrun -sdk ${sdk_name} clang -arch ${arch}"
  local cflags
  cflags="$(cflags_for_sdk "${sdk_name}" "${sdkroot}")"
  local ldflags
  ldflags="$(ldflags_for_sdk "${sdk_name}" "${sdkroot}")"

  rm -rf "${prefix}"
  mkdir -p "${prefix}"

  echo "编译 libogg (${LIBOGG_VERSION}) — ${sdk_name}/${arch} -> ${prefix}"
  (
    cd "${OGG_SRC}"
    if [[ -f Makefile ]]; then
      make distclean || true
    fi
    ./configure \
      --host="${host}" \
      --prefix="${prefix}" \
      --enable-static \
      --disable-shared \
      CC="${cc}" \
      CFLAGS="${cflags}" \
      LDFLAGS="${ldflags}"
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    make install
  )

  rm -rf "${prefix}/libogg-headers-for-xc"
  mkdir -p "${prefix}/libogg-headers-for-xc"
  cp -R "${prefix}/include/ogg" "${prefix}/libogg-headers-for-xc/"

  export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  echo "编译 libopus (${OPUS_VERSION}) — ${sdk_name}/${arch}"
  (
    cd "${OPUS_SRC}"
    if [[ -f Makefile ]]; then
      make distclean || true
    fi
    ./configure \
      --host="${host}" \
      --prefix="${prefix}" \
      --enable-static \
      --disable-shared \
      --disable-doc \
      --disable-extra-programs \
      CC="${cc}" \
      CFLAGS="${cflags}" \
      LDFLAGS="${ldflags}"
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    make install
  )

  rm -rf "${prefix}/libopus-headers-for-xc"
  mkdir -p "${prefix}/libopus-headers-for-xc"
  cp -R "${prefix}/include/opus" "${prefix}/libopus-headers-for-xc/"
}

PREFIX_IOS="${BUILD_ROOT}/ios-arm64"
PREFIX_SIM_ARM64="${BUILD_ROOT}/ios-sim-arm64"
PREFIX_SIM_X86="${BUILD_ROOT}/ios-sim-x86_64"
SIM_UNI="${BUILD_ROOT}/ios-sim-universal"

build_ogg_opus_for_prefix iphoneos arm64 aarch64-apple-darwin "${PREFIX_IOS}"
build_ogg_opus_for_prefix iphonesimulator arm64 aarch64-apple-darwin "${PREFIX_SIM_ARM64}"
build_ogg_opus_for_prefix iphonesimulator x86_64 x86_64-apple-darwin "${PREFIX_SIM_X86}"

mkdir -p "${SIM_UNI}/lib"
lipo -create \
  "${PREFIX_SIM_ARM64}/lib/libogg.a" \
  "${PREFIX_SIM_X86}/lib/libogg.a" \
  -output "${SIM_UNI}/lib/libogg.a"
lipo -create \
  "${PREFIX_SIM_ARM64}/lib/libopus.a" \
  "${PREFIX_SIM_X86}/lib/libopus.a" \
  -output "${SIM_UNI}/lib/libopus.a"

rm -rf "${OUT_DIR}/libogg.xcframework" "${OUT_DIR}/libopus.xcframework"

echo "生成 libogg.xcframework…"
xcodebuild -create-xcframework \
  -library "${PREFIX_IOS}/lib/libogg.a" \
  -headers "${PREFIX_IOS}/libogg-headers-for-xc" \
  -library "${SIM_UNI}/lib/libogg.a" \
  -headers "${PREFIX_SIM_ARM64}/libogg-headers-for-xc" \
  -output "${OUT_DIR}/libogg.xcframework"

echo "生成 libopus.xcframework…"
xcodebuild -create-xcframework \
  -library "${PREFIX_IOS}/lib/libopus.a" \
  -headers "${PREFIX_IOS}/libopus-headers-for-xc" \
  -library "${SIM_UNI}/lib/libopus.a" \
  -headers "${PREFIX_SIM_ARM64}/libopus-headers-for-xc" \
  -output "${OUT_DIR}/libopus.xcframework"

touch "${STAMP}"
echo "完成: ${OUT_DIR}/libogg.xcframework, ${OUT_DIR}/libopus.xcframework"
