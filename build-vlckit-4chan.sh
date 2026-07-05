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
# This script builds each architecture slice individually without the `-f`
# flag, then manually combines them into a single XCFramework. This avoids
# the conflicts and missing-framework errors seen with the single-command
# approach.
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
# 3. Build a single architecture slice (without -f)
#    $1 = -s or empty (for simulator/device)
#    $2 = architecture (aarch64 or x86_64)
#    Output framework will be in $BUILD_DIR/VLCKit.framework
#    We'll move it to a unique location after building.
# ---------------------------------------------------------------------------
build_slice() {
  local sim_flag="$1"
  local arch="$2"
  local slice_name="$3"   # e.g. "device", "sim-arm64", "sim-x86_64"

  cd "${VLCKIT_DIR}"

  export VLC_EXTRA_CONFIGURE_OPTS="${CONFIGURE_EXTRA_FLAGS[*]}"
  log "Building slice: ${slice_name} (${arch})"

  # Build without -f
  if [[ -z "${sim_flag}" ]]; then
    ./compileAndBuildVLCKit.sh -a "${arch}"
  else
    ./compileAndBuildVLCKit.sh -s -a "${arch}"
  fi

  # The framework is now at $BUILD_DIR/VLCKit.framework
  local src_fw="${BUILD_DIR}/VLCKit.framework"
  if [[ ! -d "${src_fw}" ]]; then
    fail "Framework not found at ${src_fw} for slice ${slice_name}"
  fi

  # Move to a unique location
  local dest_fw="${BUILD_DIR}/slices/${slice_name}/VLCKit.framework"
  mkdir -p "$(dirname "${dest_fw}")"
  mv "${src_fw}" "${dest_fw}"
  log "Moved framework to ${dest_fw}"
}

# ---------------------------------------------------------------------------
# 4. Build all slices and combine into XCFramework
# ---------------------------------------------------------------------------
build_xcframework() {
  # Clean build directory
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}/slices"

  # Build device arm64
  build_slice "" "aarch64" "device"

  # Build simulator arm64
  build_slice "-s" "aarch64" "sim-arm64"

  # Build simulator x86_64
  build_slice "-s" "x86_64" "sim-x86_64"

  # Now combine all slices into one XCFramework
  log "Creating XCFramework from all slices..."
  local xcframework_path="${BUILD_DIR}/VLCKit.xcframework"

  # Find all framework paths
  local frameworks=()
  while IFS= read -r -d '' fw; do
    frameworks+=("-framework" "${fw}")
  done < <(find "${BUILD_DIR}/slices" -name "*.framework" -print0)

  if [[ ${#frameworks[@]} -eq 0 ]]; then
    fail "No frameworks found to combine"
  fi

  # Combine
  xcodebuild -create-xcframework "${frameworks[@]}" -output "${xcframework_path}"

  if [[ ! -d "${xcframework_path}" ]]; then
    fail "XCFramework creation failed - output not found at ${xcframework_path}"
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
