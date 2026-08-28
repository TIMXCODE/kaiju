# Kaiju

A rolling-replay clipper for macOS. It sits in the background while you play,
keeps the last N seconds in a buffer, and writes that buffer to a file the instant
you press a key — so you never have to have started recording.

Native Swift + SwiftUI, ScreenCaptureKit, VideoToolbox, Core Audio, Core Image on
Metal. **Zero third-party dependencies.** Built for Apple Silicon, macOS 15+.

---

## Open it

```
open Kaiju.xcodeproj
```

Pick the **Kaiju** scheme and hit Run. The project ships with ad-hoc signing
(`CODE_SIGN_IDENTITY = "-"`) so it builds with no configuration at all.

> **Worth doing once:** in *Signing & Capabilities*, switch Code Signing to
> **Automatic** and pick your team. Ad-hoc signatures change on every build, and
> macOS ties the Screen Recording grant to the signature — so with ad-hoc you'll
> re-grant permission after most rebuilds. With a real signing identity you grant
> it once.

## Prove the engine before you trust the UI

The recording engine is a separate Swift package with no UI and no AppKit
dependency, so it can be run and tested on its own:

```bash
cd KaijuKit

swift test                 # ring buffer, eviction, clip extraction, edit maths

swift run kaijuctl doctor  # permissions, hardware encoders, capture sources
swift run kaijuctl sources # every display / window / app SCK can capture

# Run a real 30s buffer, then save the last 15s out of it — twice, to prove
# saving doesn't interrupt capture:
swift run kaijuctl record --seconds 30 --clip 15 --clips 2

# Hold a 2-minute buffer for 10 minutes and print RSS every 5s.
# A healthy run flattens out once the buffer fills and stays there.
swift run kaijuctl soak --seconds 600 --buffer 120
```

`kaijuctl` inherits Screen Recording permission from the terminal you run it in,
so grant Terminal (or Xcode) that permission first.

---

## How the replay buffer actually works

This is the part everything else hangs off, so it's worth being precise.

**Video is stored already-encoded.** Frames come out of ScreenCaptureKit as
`420v` bi-planar pixel buffers — the exact format the hardware encoder wants, so
there's no colour conversion — and go straight into a VideoToolbox session running
in real-time, low-latency mode with frame reordering off. The compressed bytes
land in a fixed-size circular arena. Saving a clip is therefore a *copy and a
mux*, not an encode: pressing the hotkey produces a file in well under a second no
matter how long the clip is, and costs almost no CPU while a game is running.

**No B-frames** means presentation order equals decode order, which is what lets a
clip be sliced out of the middle of the stream without re-encoding anything.
Clips start at the nearest keyframe at or before the point you asked for — with a
1-second keyframe interval that's at most one second of extra lead-in, which for a
replay clip is a feature.

**Audio is stored as raw PCM** and compressed to AAC only when a clip is written.
At 48 kHz stereo that's ~384 KB/s against video's ~2.5 MB/s — a rounding error —
and it removes an entire real-time audio encoder from the capture path.

**Memory is flat by construction.** `ByteRing` allocates once at start-up and
memcpy's into the same region forever; `RecordDeque` is an amortised-O(1) deque so
dropping 60 records a second for six hours doesn't turn into an O(n²) memmove.
Nothing about the design grows with runtime — that's what `kaijuctl soak` checks.

**Long buffers move to disk.** Half an hour of 1080p60 is a couple of gigabytes,
which doesn't belong in RAM. Past the memory budget Kaiju switches to a rotating
ring of self-contained segment files, each starting on a keyframe, one file every
10–60 seconds depending on buffer length — dozens per session, not thousands.
Saving *pins* the segments it needs, so rotation can keep deleting around them and
a save never blocks capture.

**Saving never stops the buffer.** Taking a snapshot is a copy, not a handoff. The
ring keeps ingesting the whole time, which is why you can fire the hotkey five
times in a row.

### A/V sync

ScreenCaptureKit timestamps video, system audio *and* the microphone against the
same host clock. The mixer anchors both audio sources to the first sample's
timestamp and writes each into a frame-indexed jitter ring, so lining them up is
arithmetic rather than guesswork: each source lands at the index its own timestamp
says it belongs at, and gaps become silence instead of drift. Audio isn't nudged
to fit the video — it's placed where its timestamp puts it.

---

## Layout

```
Kaiju.xcodeproj          Xcode 16+ project (file-system-synchronised groups —
                         new files are picked up automatically)
Config/                  Info.plist + entitlements
App/                     SwiftUI app: shell, screens, menu bar, overlay
KaijuKit/                The engine, as a standalone Swift package
  Sources/KaijuKit/
    Capture/             ScreenCaptureKit stream, source catalogue, statistics
    Encoding/            VideoToolbox compression session
    Buffer/              ByteRing, memory store, disk-segment store
    Audio/               format conversion, jitter rings, mixer, monitoring
    Clips/               sample-buffer construction, clip writing, library
    Export/              edit plan, Core Image render pipeline, export jobs
    Games/               application detection
    Hotkeys/             Carbon global hot keys
    Performance/         mach-based CPU / memory metrics
    Permissions/ Settings/ Storage/ Notifications/ Share/ Support/
    Engine/              pipeline, app-facing controller, headless recorder
  Sources/kaijuctl/      CLI harness
  Tests/KaijuKitTests/   unit tests
```

The UI **observes** the engine; it never drives capture directly. That's why
hiding the window, switching sections, or closing everything but the menu bar
can't disturb a running buffer.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Instant Replay | ⌘⌥I |
| Capture Clip | ⌘⌥C |
| Start / Stop buffer | ⌘⌥R |
| Show / Hide Kaiju | ⌘⌥H |
| Mute / Unmute mic | ⌘⌥M |

All reassignable. They're registered through Carbon's `RegisterEventHotKey`, which
is the only way to get a shortcut that fires while a full-screen game holds
keyboard focus — and unlike a CGEvent tap it needs no Accessibility permission and
never sees a key you didn't assign.

## Permissions

- **Screen & System Audio Recording** — required. This is the app. System and game
  audio come through the same grant.
- **Microphone** — only if you turn mic capture on. Leave it off and Kaiju never
  opens an input device.
- **Notifications** — optional, for the "clip saved" confirmation and warnings.

Kaiju is deliberately **not sandboxed**: a clipper has to write to wherever you
keep videos and read the list of running applications. Hardened runtime is on for
Release builds.

## Things that are deliberately not done

- **No cloud, no account.** Sharing goes through the macOS share sheet, so it
  reaches whatever you already have installed. `UploadProvider` is a protocol with
  no implementations — Discord/YouTube/S3 can drop in later without the clipping
  engine knowing they exist.
- **Automatic cleanup is off by default,** and shows you what it *would* delete
  before you enable it. Favourites are protected. Deletions go to the Trash.
- **Nothing in the performance panel is estimated.** CPU and memory come from
  mach, frame rate is counted from stream callbacks, bitrate is measured from bytes
  the encoder actually emitted, buffer figures come from the ring itself.

## Known limits

- 120 fps is offered but only sensible if your display and game genuinely run
  there; it doubles the bitrate.
- Clip start snaps to a keyframe (configurable, 0.5–4 s). Editor trims are
  frame-exact because the editor re-encodes.
- With a disk-backed buffer, a save has to flush the in-progress segment first —
  typically under 200 ms, and ingest keeps flowing the whole time.
