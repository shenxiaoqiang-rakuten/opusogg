#!/usr/bin/env bash
# Aggregate Target「OpusOGGXCFrameworkBuilder」：在独立 DerivedData 中分别编出真机与模拟器，
# 再用 xcodebuild -create-xcframework 生成 Distribution/OpusOGG.xcframework（勿放在 OpusOGG/ 源码树下，
# 且勿留下不完整的 OpusOGG.xcframework 空目录，否则 File System Sync 会按 xcframework 解析并报缺 Info.plist）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SRCROOT:-}" ]]; then
  SRCROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

PROJECT="${SRCROOT}/OpusOGGContainer.xcodeproj"
CONFIG="${CONFIGURATION:-Release}"
# 输出放在项目根目录的 Distribution/，避免位于 OpusOGG 源码树下被同步组当成依赖处理。
OUT="${SRCROOT}/Distribution/OpusOGG.xcframework"
WORK="${SRCROOT}/Vendor/xcframework-dist"

echo "OpusOGGXCFrameworkBuilder: CONFIG=${CONFIG}, SRCROOT=${SRCROOT}"

rm -rf "${OUT}" "${WORK}"
mkdir -p "${WORK}"

DERIVED_IOS="${WORK}/DerivedData-ios"
DERIVED_SIM="${WORK}/DerivedData-sim"

xcodebuild \
  -project "${PROJECT}" \
  -scheme OpusOGG \
  -configuration "${CONFIG}" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED_IOS}" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build

xcodebuild \
  -project "${PROJECT}" \
  -scheme OpusOGG \
  -configuration "${CONFIG}" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${DERIVED_SIM}" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build

FW_IOS="${DERIVED_IOS}/Build/Products/${CONFIG}-iphoneos/OpusOGG.framework"
FW_SIM="${DERIVED_SIM}/Build/Products/${CONFIG}-iphonesimulator/OpusOGG.framework"

if [[ ! -d "${FW_IOS}" ]]; then
  echo "error: 未找到 ${FW_IOS}" >&2
  exit 1
fi
if [[ ! -d "${FW_SIM}" ]]; then
  echo "error: 未找到 ${FW_SIM}" >&2
  exit 1
fi

# OpusOGG sets SWIFT_EMIT_MODULE_INTERFACE=YES so each slice ships *.swiftinterface; then
# create-xcframework succeeds without -allow-internal-distribution (better for older Xcode).
xcodebuild -create-xcframework \
  -framework "${FW_IOS}" \
  -framework "${FW_SIM}" \
  -output "${OUT}"

for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  bin="${OUT}/${slice}/OpusOGG.framework/OpusOGG"
  if [[ ! -f "${bin}" ]]; then
    echo "error: missing binary in xcframework slice: ${bin}" >&2
    exit 1
  fi
done

echo "已生成: ${OUT}"
