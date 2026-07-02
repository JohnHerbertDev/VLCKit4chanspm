# VLCKit4chan

A codec-stripped VLCKit build system for iOS that plays 4chan media files
that iOS cannot handle natively — directly in-app, without transcoding.

**Adds ~25–45 MB to your IPA.** Builds from VLCKit and VLC `master` on a
weekly schedule so you always ship the latest decoder fixes.

---

## How it works

iOS cannot play WebM or OGG files via AVFoundation. This library embeds a
minimal VLC media player core so your app can play those files directly,
without converting them first.

```
URLSession.downloadTask()        ← download any 4chan file
         ↓
file extension check
  .webm  →  VLCMediaPlayer      plays VP8/VP9 + Vorbis/Opus directly
  .ogg   →  VLCMediaPlayer      plays Vorbis directly
  else   →  AVPlayer            MP4, MP3, FLAC handled by iOS natively
```

The VLC player renders directly to a `UIView`. No transcode step, no
intermediate file — the original WebM plays as downloaded.

---

## FFmpeg4chan vs VLCKit4chan — which should I use?

| | VLCKit4chan | FFmpeg4chan |
|---|---|---|
| Approach | Play WebM/OGG directly | Transcode WebM/OGG → MP4/M4A first |
| IPA size | ~25–45 MB | ~3–6 MB |
| Integration | `VLCMediaPlayer` UI component | FFmpeg C API + AVPlayer |
| Output files | Original format (WebM stays WebM) | Converted (WebM → MP4) |
| Shared to Photos/Files | ❌ iOS can't open WebM | ✅ MP4 works everywhere |
| Build time | ~60–90 min | ~45–60 min |

**Use VLCKit** if you want to play files in-app without converting them and
don't need users to export/share the original file to other apps.

**Use FFmpeg** if you want to save files in a format the iOS Photos app,
Files app, AirDrop, and other apps can open — or if IPA size matters.

---

## Codec scope

| Module | Type | Purpose |
|---|---|---|
| `matroska` | demuxer | WebM + MKV container |
| `ogg` | demuxer | OGG container |
| `vpx` | decoder | VP8 + VP9 video (via libvpx) |
| `vorbis` | decoder | Vorbis audio |
| `opus` | decoder | Opus audio |

Everything else is disabled: H.264, HEVC, AAC, MP3, ALAC, subtitle codecs,
DVD/Blu-ray, all streaming protocols (RTSP, HTTP live, SMB, NFS, FTP).
VLC core itself (~8–12 MB) ships regardless of codec selection — it is the
unavoidable overhead of the VLC framework.

---

## Requirements

### Local builds
- macOS 13 or later
- Xcode 15 or later with Command Line Tools (`xcode-select --install`)
- Git

### GitHub Actions
- A GitHub repository with Actions enabled
- `GITHUB_TOKEN` write permissions for releases (see [setup](#github-setup))

> ⚠️ VLCKit builds are substantially longer than FFmpeg builds (~60–90 min
> locally, up to 3 hours on GitHub Actions runners). Plan accordingly.

---

## GitHub Setup

### 1. Create a new repository

Go to [github.com/new](https://github.com/new) and create a repository.
Name it something like `VLCKit4chan` or `vlckit-ios-4chan`.
Public or private both work.

### 2. Add the files

Clone your new repo and copy in the project files:

```bash
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>

# Copy in the project files
cp /path/to/build-vlckit-4chan.sh .
cp /path/to/run-local.sh .
cp /path/to/Package.swift .
cp /path/to/CLAUDE.md .
mkdir -p .github/workflows
cp /path/to/build-vlckit.yml .github/workflows/
```

### 3. Add a .gitignore

```bash
cat > .gitignore << 'EOF'
.build/
output/
*.xcframework
*.zip
*.sha256
EOF
```

### 4. Configure Actions permissions

In your repo on GitHub:
1. Go to **Settings → Actions → General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Check **Allow GitHub Actions to create and approve pull requests**
4. Click **Save**

This allows the workflow to publish GitHub Releases.

### 5. Push

```bash
git add .
git commit -m "Initial VLCKit4chan build system"
git push origin main
```

### 6. Run the workflow manually (first build)

1. Go to your repo on GitHub
2. Click the **Actions** tab
3. Select **Build VLCKit (4chan codec subset)** from the left sidebar
4. Click **Run workflow → Run workflow**

> The first build takes **60–90 minutes** on a GitHub Actions macOS runner.
> This is normal — VLC core is a large project. Subsequent builds take
> roughly the same time since we always clone from master.

When it completes:
- A GitHub Release is published with `VLCKit.xcframework.zip` and
  `VLCKit.xcframework.zip.sha256` as assets
- The build log (expand the **Print Package.swift snippet** step) shows
  the exact `url` and `checksum` to paste into `Package.swift`

### 7. Update Package.swift

Open `Package.swift` and replace the placeholder values:

```swift
.binaryTarget(
    name: "VLCKit4chan",
    url: "https://github.com/<your-username>/<your-repo>/releases/download/<tag>/VLCKit.xcframework.zip",
    checksum: "<sha256-from-build-log>"
)
```

Commit and push.

---

## Local builds

Use the local build when iterating on the codec strip list or debugging
`VLC_EXTRA_CONFIGURE_OPTS` forwarding before committing to a long CI run.

```bash
# Make scripts executable (only needed once)
chmod +x build-vlckit-4chan.sh run-local.sh

# Run the build (~60–90 minutes)
./run-local.sh
```

Output lands in `./output/`:
```
output/
  VLCKit.xcframework            ← point Package.swift path target here
  VLCKit.xcframework.zip
  VLCKit.xcframework.zip.sha256
```

**Verify the strip worked** by checking the build log for your
`--disable-x264` and other flags appearing in the actual VLC `configure`
invocation. If they don't appear, see the
[`VLC_EXTRA_CONFIGURE_OPTS` troubleshooting](#vlc_extra_configure_opts-troubleshooting)
section below.

**While iterating locally**, use a `path`-based `binaryTarget` so you don't
need a published release:

```swift
.binaryTarget(
    name: "VLCKit4chan",
    path: "./output/VLCKit.xcframework"
)
```

---

## Adding to your iOS app

### Via Swift Package Manager (Xcode)

1. In Xcode: **File → Add Package Dependencies**
2. Enter your repo URL: `https://github.com/<your-username>/<your-repo>`
3. Select the version rule (exact version recommended for binary targets)
4. Add **VLCKit4chan** to your app target

### Via Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/<your-username>/<your-repo>", from: "<tag>")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["VLCKit4chan"]
    )
]
```

---

## Using VLCKit in your app

```swift
import VLCKit4chan

class PlayerViewController: UIViewController {
    private let mediaPlayer = VLCMediaPlayer()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Attach player output to a view
        mediaPlayer.drawable = self.view
    }

    func play(fileURL: URL) {
        let media = VLCMedia(url: fileURL)
        mediaPlayer.media = media
        mediaPlayer.play()
    }

    func stop() {
        mediaPlayer.stop()
    }
}
```

**Routing logic** — only send unsupported formats to VLC:

```swift
func play(_ url: URL) {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "webm", "ogg":
        // VLCKit handles these
        vlcPlayerViewController.play(fileURL: url)
    default:
        // AVFoundation handles MP4, MP3, FLAC, etc.
        let player = AVPlayer(url: url)
        avPlayerViewController.player = player
        avPlayerViewController.player?.play()
    }
}
```

---

## VLC_EXTRA_CONFIGURE_OPTS troubleshooting

The codec strip relies on the `VLC_EXTRA_CONFIGURE_OPTS` environment variable
being forwarded from VLCKit's build wrapper down into VLC core's `configure`
call. This is the most fragile part of the build — if VLC upstream changes
how the apple build script accepts extra configure flags, the strip silently
stops working (the build succeeds but codecs aren't removed).

**How to verify the strip is working:**

After a local build, search the build log for one of your disable flags:

```bash
grep -r "disable-x264" .build/vlckit/build/ 2>/dev/null | head -5
```

If nothing appears, open
`.build/vlckit/libvlc/vlc/extras/package/apple/build.sh` and search for
where it calls `configure`. Find the correct variable or argument to pass
extra flags and update `build_xcframework()` in `build-vlckit-4chan.sh`.

**If `verify_flags()` fails:**

The module name changed in VLC core upstream. Check what changed:

```bash
# In the cloned VLC repo
git -C .build/vlckit/libvlc/vlc log --oneline -20 -- configure.ac
```

Find the new name and update `DISABLE_MODULES` or `ENABLE_MODULES` in
`build-vlckit-4chan.sh`.

---

## Scheduled builds

The GitHub Actions workflow runs automatically every **Monday at 06:00 UTC**
(offset one day from the companion FFmpeg workflow to avoid simultaneous
macOS runner contention). Each build clones the latest VLCKit and VLC `master`
and publishes a new release if the build succeeds.

The release tag embeds the date and run number. You will need to manually
update `Package.swift` with the new URL and checksum after each automated
build — SPM binary targets do not auto-update.

---

## Known limitations

- **Build time is long.** VLC core is a large project. ~60–90 min locally,
  up to 3 hours on GitHub Actions macOS runners. There is no way to
  meaningfully speed this up short of caching the VLC contrib dependencies
  (a possible future improvement — contributions welcome).

- **`VLC_EXTRA_CONFIGURE_OPTS` forwarding is not a stable API.** If VLC
  upstream changes how its apple build script accepts extra flags, the codec
  strip may silently stop working. See troubleshooting above.

- **VLC core is irreducible.** Even with all optional modules disabled, VLC
  core itself (~8–12 MB uncompressed) ships in every build. This is the main
  driver of the ~25–45 MB IPA size delta. If size is a concern, use
  FFmpeg4chan instead.

- **Module names change across VLC releases.** The `DISABLE_MODULES` list has
  historically broken when VLC reorganised its audio/video module hierarchy.
  `verify_flags()` will catch this and fail loudly rather than silently
  building an unstripped binary.

---

## License

VLCKit and VLC core are licensed under the **LGPL 2.1**. Your app must
comply with LGPL requirements. For an iOS static framework, the standard
approach is to publish your build scripts (which this repo already does),
allowing users to relink with a modified VLC.

See [videolan.org/legal](https://www.videolan.org/legal) for full details.
