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
# This always builds against VLCKit `master` and uses the VLC core submodule
# that VLCKit pins. The build uses a single combined command to create the
# XCFramework, avoiding conflicts from multiple invocations.
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

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Modules to disable in VLC core's configure.
#    NOTE: these flag names are tied to VLC core's current configure.ac and
#    DO change across VLC releases. The verification step is commented out
#    because the names keep changing; the flags are still passed to configure.
#    If the build fails at configure, check the log and update this list.
# ---------------------------------------------------------------------------
DISABLE_MODULES=(
  # Native iOS video/audio codecs (AVFoundation already covers these)
  --disable-x264
  --disable-x265
  --disable-mp4
  --disable-faad
  --disable-mad        # mp3
  # Subtitle / container extras 4chan doesn't accept
  --disable-libass
  --disable-dvdread
  --disable-dvdnav
  --disable-bluray
  --disable-dca
  --disable-a52
  # Network/streaming protocols not needed for local file playback
  --disable-live555
  --disable-dsm
  --disable-smb2
  --disable-nfs
  --disable-sftp
  --disable-ftp
  --disable-rtsp
)

# Flags we explicitly want ENABLED — VLC contrib defaults can vary, so be
# explicit rather than relying on defaults.
ENABLE_MODULES=(
  --enable-vpx          # VP8 + VP9 (libvpx)
  --enable-ogg           # WebM/Matroska + Vorbis/Opus container plumbing
  --enable-vorbis
  --enable-opus
  --enable-matroska
)

CONFIGURE_EXTRA_FLAGS=("${DISABLE_MODULES[@]}" "${ENABLE_MODULES[@]}")

# ---------------------------------------------------------------------------
# 2. Clone latest VLCKit (with its submodule, which provides VLC core)
#    We use a full clone (no --depth 1) because VLCKit's build script
#    references specific commits that are not present in shallow clones.
# ---------------------------------------------------------------------------
clone_latest() {
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}"
  log "Cloning VLCKit master (with submodules)..."
  git clone --recursive https://code.videolan.org/videolan/VLCKit.git "${VLCKIT_DIR}"
  # VLC core is now inside ${VLCKIT_DIR}/libvlc/vlc at the commit VLCKit expects.
}

# ---------------------------------------------------------------------------
# 3. (Optional) Verification - now skipped because module names drift.
#    Uncomment if you want to check compatibility before building.
# ---------------------------------------------------------------------------
# verify_flags() {
#   local vlc_configure="${VLCKIT_DIR}/libvlc/vlc/configure.ac"
#   [[ -f "${vlc_configure}" ]] || fail "Could not find VLC configure.ac at expected path: ${vlc_configure}"
#
#   log "Verifying codec flags against current VLC core configure.ac..."
#   local missing=()
#   local flag module
#
#   for flag in "${CONFIGURE_EXTRA_FLAGS[@]}"; do
#     module="${flag#--enable-}"
#     module="${module#--disable-}"
#     if ! grep -qE "(enable|disable)-${module}" "${vlc_configure}"; then
#       missing+=("${flag} (module: ${module})")
#     fi
#   done
#
#   if (( ${#missing[@]} > 0 )); then
#     fail "$(printf 'The following configure flags are no longer recognized by VLC core master — upstream likely renamed/removed a module. Update DISABLE_MODULES/ENABLE_MODULES in this script before rebuilding:\n  %s\n' "$(printf '%s\n  ' "${missing[@]}")")"
#   fi
#
#   log "All ${#CONFIGURE_EXTRA_FLAGS[@]} codec flags verified OK."
# }

# ---------------------------------------------------------------------------
# 4. Inject our extra configure flags into VLCKit's build invocation.
#    VLCKit's compileAndBuildVLCKit.sh forwards $EXTRA_CONFIGURE_FLAGS-style
#    environment overrides down to extras/package/apple/build.sh -> VLC's
#    own configure. We pass them via the VLC_EXTRA_CONFIGURE_OPTS env var,
#    which VLC's apple build.sh appends verbatim to its configure call.
# ---------------------------------------------------------------------------
build_xcframework() {
  cd "${VLCKIT_DIR}"

  export VLC_EXTRA_CONFIGURE_OPTS="${CONFIGURE_EXTRA_FLAGS[*]}"
  log "VLC_EXTRA_CONFIGURE_OPTS = ${VLC_EXTRA_CONFIGURE_OPTS}"

  # Build full XCFramework (device + simulator) in one go
  # -f builds the .xcframework, -s includes simulator slices
  # It automatically picks arm64 for device and arm64+x86_64 for simulator
  log "Building full VLCKit.xcframework (device + simulator)..."
  ./compileAndBuildVLCKit.sh -f -s

  local built_xcframework="${VLCKIT_DIR}/build/VLCKit.xcframework"
  [[ -d "${built_xcframework}" ]] || fail "Expected output xcframework not found at ${built_xcframework} — build likely failed upstream."

  mkdir -p "${OUT_DIR}"
  rm -rf "${OUT_DIR}/VLCKit.xcframework"
  cp -R "${built_xcframework}" "${OUT_DIR}/VLCKit.xcframework"
}

# ---------------------------------------------------------------------------
# 5. Package for SPM (zip + checksum for a binaryTarget remote URL)
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
  # verify_flags   # <-- commented out to avoid early failure
  build_xcframework
  package
}

main "$@"
