#!/usr/bin/env bash
#
# build-vlckit-4chan.sh
#
# Builds a stripped-down VLCKit.xcframework (iOS device + iOS Simulator,
# arm64 + x86_64) containing ONLY the codecs 4chan actually accepts that
# iOS does not already play natively via AVFoundation:
#
#   Demux:  WebM / Matroska
#   Video:  VP8, VP9
#   Audio:  Vorbis, Opus
#
# Explicitly excluded (iOS/AVFoundation already handles these, and/or
# 4chan doesn't accept them): H.264, HEVC, AAC, MP3, ALAC, MP4/MOV demux,
# subtitles, DVD/BluRay, RTSP/streaming protocols, etc.
#
# This script invokes VLCKit's own compileAndBuildVLCKit.sh once; that
# script builds every required device/simulator architecture internally
# and writes a single already-combined VLCKit.xcframework, which we then
# copy into ./output and package for SPM.
#
# Usage:
#   ./build-vlckit-4chan.sh
#
# Output:
#   ./output/VLCKit.xcframework
#   ./output/VLCKit.xcframework.zip
#   ./output/VLCKit.xcframework.zip.sha256
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${ROOT_DIR}/.build"
OUT_DIR="${ROOT_DIR}/output"
VLCKIT_DIR="${WORK_DIR}/vlckit"
BUILD_DIR="${VLCKIT_DIR}/build"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Modules to disable in VLC core's configure.
# ---------------------------------------------------------------------------
DISABLE_MODULES=(
  --disable-x264
  --disable-x265
  --disable-mp4
  --disable-faad
  --disable-mad
  --disable-libass
  --disable-dvdread
  --disable-dvdnav
  --disable-bluray
  --disable-dca
  --disable-a52
  --disable-live555
  --disable-dsm
  --disable-smb2
  --disable-nfs
  --disable-sftp
  --disable-ftp
  --disable-rtsp
)

ENABLE_MODULES=(
  --enable-vpx
  --enable-ogg
  --enable-vorbis
  --enable-opus
  --enable-matroska
)

CONFIGURE_EXTRA_FLAGS=("${DISABLE_MODULES[@]}" "${ENABLE_MODULES[@]}")

# ---------------------------------------------------------------------------
# 2. Clone latest VLCKit (with its submodule)
# ---------------------------------------------------------------------------
clone_latest() {
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}"
  log "Cloning VLCKit master (with submodules)..."
  git clone --recursive https://code.videolan.org/videolan/VLCKit.git "${VLCKIT_DIR}"
}

# ---------------------------------------------------------------------------
# 3. Build the universal XCFramework
#
#    NOTE: Earlier versions of this script called
#    compileAndBuildVLCKit.sh once per architecture/platform (expecting a
#    bare VLCKit.framework to appear at $BUILD_DIR/VLCKit.framework each
#    time), then hand-assembled the slices with `xcodebuild
#    -create-xcframework`. Current upstream VLCKit (master) no longer works
#    that way: a single invocation of compileAndBuildVLCKit.sh builds every
#    device/simulator architecture itself and writes one already-combined
#    VLCKit.xcframework directly to
#    ${BUILD_DIR}/iOS/VLCKit.xcframework.
#    The per-slice approach failed with:
#      "Framework not found at .../build/VLCKit.framework for slice device"
#    because that intermediate bare-framework path is never produced.
#    We now just call the script once and copy its finished output.
# ---------------------------------------------------------------------------
build_xcframework() {
  # Clean build directory
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"

  cd "${VLCKIT_DIR}"

  export VLC_EXTRA_CONFIGURE_OPTS="${CONFIGURE_EXTRA_FLAGS[*]}"
  log "Building universal VLCKit.xcframework (device + simulator, arm64 + x86_64)..."

  # No -a/-s flags: this builds every required platform/arch slice
  # internally and combines them into a single xcframework itself.
  ./compileAndBuildVLCKit.sh

  local xcframework_path="${BUILD_DIR}/iOS/VLCKit.xcframework"
  if [[ ! -d "${xcframework_path}" ]]; then
    fail "XCFramework not found at ${xcframework_path}"
  fi

  # Copy to output directory
  mkdir -p "${OUT_DIR}"
  rm -rf "${OUT_DIR}/VLCKit.xcframework"
  cp -R "${xcframework_path}" "${OUT_DIR}/VLCKit.xcframework"
  log "XCFramework copied to ${OUT_DIR}/VLCKit.xcframework"
}

# ---------------------------------------------------------------------------
# 5. Package for SPM
# ---------------------------------------------------------------------------
package() {
  cd "${OUT_DIR}"
  log "Zipping xcframework..."
  rm -f VLCKit.xcframework.zip
  zip -r -y -q VLCKit.xcframework.zip VLCKit.xcframework

  log "Computing checksum..."
  swift package compute-checksum VLCKit.xcframework.zip > VLCKit.xcframework.zip.sha256 \
    || shasum -a 256 VLCKit.xcframework.zip | awk '{print $1}' > VLCKit.xcframework.zip.sha256

  log "Done."
  log "  Output:   ${OUT_DIR}/VLCKit.xcframework.zip"
  log "  Checksum: $(cat VLCKit.xcframework.zip.sha256)"
}

main() {
  clone_latest
  # verify_flags   # (commented out – uncomment if you want to check module names)
  build_xcframework
  package
}

main "$@"
