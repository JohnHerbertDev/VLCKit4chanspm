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
# 1. Modules to disable / enable.
#
#    IMPORTANT: These flags do nothing on their own. An earlier version of
#    this script exported them as $VLC_EXTRA_CONFIGURE_OPTS, but that
#    environment variable is never read anywhere in VLCKit's
#    compileAndBuildVLCKit.sh or in VLC's own extras/package/apple/build.sh
#    -- it was silently ignored from the very first run, which is why past
#    builds produced a full ~214 MB unstripped VLCKit instead of the
#    expected ~25-45 MB.
#
#    The mechanism VLC's Apple build scripts actually read is a config
#    file inside the VLC checkout itself:
#      extras/package/apple/build.conf
#    which defines (among others) these per-platform arrays:
#      VLC_CONTRIB_OPTIONS_IOS   -> forwarded to the contrib bootstrap
#                                    (controls which 3rd-party libs, e.g.
#                                    ffmpeg/x264/opencv/protobuf, get BUILT
#                                    as static libs at all)
#      VLC_CONFIG_OPTIONS_IOS    -> forwarded to VLC core's ./configure
#                                    (controls which VLC *modules* get
#                                    compiled against those libs)
#      VLC_MODULE_REMOVAL_LIST_IOS -> specific modules stripped after build
#
#    See build_xcframework() below for how these are actually applied by
#    patching build.conf inside the freshly cloned VLC checkout, since
#    compileAndBuildVLCKit.sh clones VLC itself and there is no supported
#    way to inject these flags purely via environment variables.
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
# 3. Clone latest VLCKit (with its submodule)
# ---------------------------------------------------------------------------
clone_latest() {
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}"
  log "Cloning VLCKit master (with submodules)..."
  git clone --recursive https://code.videolan.org/videolan/VLCKit.git "${VLCKIT_DIR}"
}

# ---------------------------------------------------------------------------
# 4. Pre-clone VLC and patch its Apple build config.
#
#    compileAndBuildVLCKit.sh clones VLC itself, on demand, partway through
#    step 5 below -- so extras/package/apple/build.conf does not exist yet
#    right after clone_latest(). We clone VLC ourselves first, into the
#    exact path compileAndBuildVLCKit.sh expects (must run AFTER
#    clone_latest, since that step wipes and recreates the whole work
#    directory), patch build.conf there, then let compileAndBuildVLCKit.sh
#    find the checkout already present and skip its own clone.
#
#    NOTE (unverified, please confirm against the build log): this assumes
#    compileAndBuildVLCKit.sh only clones VLC when
#    ${VLCKIT_DIR}/libvlc/vlc doesn't already exist, which is the
#    conventional pattern for this kind of wrapper script but has not been
#    tested end-to-end here. After running, check the log for a line like
#    "Cloning VLC master" -- if it appears anyway, this pre-clone was
#    ignored and the patched build.conf may have been overwritten by a
#    fresh clone.
# ---------------------------------------------------------------------------
patch_vlc_build_conf() {
  local vlc_dir="${VLCKIT_DIR}/libvlc/vlc"

  log "Pre-cloning VLC master so we can patch its Apple build config..."
  mkdir -p "$(dirname "${vlc_dir}")"
  git clone --branch master --single-branch https://code.videolan.org/videolan/vlc.git "${vlc_dir}"

  local build_conf="${vlc_dir}/extras/package/apple/build.conf"
  if [[ ! -f "${build_conf}" ]]; then
    fail "extras/package/apple/build.conf not found in VLC checkout at ${build_conf} -- VLC upstream may have moved/renamed this file; codec strip cannot be applied"
  fi

  log "Patching ${build_conf} with codec strip flags..."
  {
    echo ""
    echo "# --- injected by build-vlckit-4chan.sh: codec strip for 4chan subset ---"
    echo "# Appended (not overwritten) so these override the defaults build.conf"
    echo "# sets earlier in the file, since bash arrays assigned later win."
    printf 'VLC_CONFIG_OPTIONS_IOS=(%s)\n' "${CONFIGURE_EXTRA_FLAGS[*]}"
    echo "export VLC_CONFIG_OPTIONS_IOS"
    printf 'VLC_CONTRIB_OPTIONS_IOS=(%s)\n' "${DISABLE_MODULES[*]}"
    echo "export VLC_CONTRIB_OPTIONS_IOS"
    echo "# --- end injected block ---"
  } >> "${build_conf}"

  log "Patched build.conf contents (tail):"
  tail -n 10 "${build_conf}"
}

# ---------------------------------------------------------------------------
# 5. Build the universal XCFramework
#
#    NOTE: Earlier versions of this script called
#    compileAndBuildVLCKit.sh once per architecture/platform (expecting a
#    bare VLCKit.framework to appear at $BUILD_DIR/VLCKit.framework each
#    time), then hand-assembled the slices with `xcodebuild
#    -create-xcframework`. That failed with:
#      "Framework not found at .../build/VLCKit.framework for slice device"
#    because current upstream VLCKit (master) doesn't produce that
#    intermediate bare-framework path.
#
#    A later fix called compileAndBuildVLCKit.sh with no flags at all,
#    which failed differently: BUILD_FRAMEWORK defaults to "no" in the
#    upstream script, so it compiles libvlc, prints "all done", and exits
#    immediately -- it never reaches the code that builds VLCKit.xcframework.
#
#    The -f flag is mandatory to actually build the xcframework. With -f
#    (and the default FARCH="all"), a single invocation builds device
#    arm64 + simulator arm64 + simulator x86_64 and combines them into one
#    already-combined VLCKit.xcframework, written to
#    ${BUILD_DIR}/iOS/VLCKit.xcframework. We just call the script once
#    (with -f) and copy its finished output.
# ---------------------------------------------------------------------------
build_xcframework() {
  # Clean build directory
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"

  cd "${VLCKIT_DIR}"

  log "Building universal VLCKit.xcframework (device + simulator, arm64 + x86_64)..."

  # IMPORTANT: -f is required. Without it, BUILD_FRAMEWORK stays at its
  # default of "no", and the upstream script exits right after printing
  # "all done" -- it never reaches the code that builds VLCKit.xcframework
  # at all. With -f (and the default FARCH="all"), a single invocation
  # builds device arm64 + simulator arm64 + simulator x86_64 and combines
  # them into one xcframework itself.
  ./compileAndBuildVLCKit.sh -f

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
# 6. Package for SPM
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
  patch_vlc_build_conf
  build_xcframework
  package

  # Sanity check: a correctly stripped build should land in roughly the
  # 25-45 MB range documented in the README. If it's dramatically larger,
  # the codec strip likely didn't take effect (e.g. build.conf wasn't
  # found/patched as expected, or compileAndBuildVLCKit.sh re-cloned VLC
  # over our patched checkout) and this needs investigating before
  # trusting the release.
  local zip_size_mb
  zip_size_mb=$(du -m "${OUT_DIR}/VLCKit.xcframework.zip" | cut -f1)
  log "Output zip size: ${zip_size_mb} MB (expected roughly 25-45 MB for a correctly stripped build)"
  if (( zip_size_mb > 80 )); then
    log "WARNING: output is much larger than expected -- the codec strip likely did not take effect. Check the build log for whether VLC was re-cloned (which would have discarded the patched build.conf) and whether the 'checking whether to enable' lines for x264/dvdnav/etc. in VLC's own configure output reflect the disable flags."
  fi
}

main "$@"
