# Open Opal: technical notes

How Open Opal works, how to build and test it, and what we know about the
hardware. For signing and releases, see [docs/SIGNING.md](docs/SIGNING.md) and
[docs/RELEASING.md](docs/RELEASING.md).

## Building

Open Opal runs on Apple silicon Macs with macOS 14 (Sonoma) or later. Liquid
Glass appears on macOS 26 and later; older versions get the classic look.

Building needs macOS 27, Xcode 27, and `brew install cmake ninja xcodegen`.

```sh
./scripts/bootstrap.sh     # fetches and builds depthai-core
./scripts/fetch-models.sh  # downloads the Core ML depth model
xcodegen generate
open OpenOpal.xcodeproj    # then build & run from Xcode (⌘R)
```

To build from the command line and install to /Applications:

```sh
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/OpenOpal.app /Applications/
```

Use Release builds for day-to-day use — Debug builds noticeably stutter in UI
animations.

The virtual camera only installs from a signed build in /Applications; see
[docs/SIGNING.md](docs/SIGNING.md). The app itself runs fine unsigned.

Bootstrap disables network-camera discovery and connections inside DepthAI.
The C1 uses USB only. Rebuild the SDK and app to update existing copies.

### First-generation C1s

First-generation IMX378 C1s use a RAM-only bootloader handoff. The pinned
DepthAI SDK patch allows only `GetBootloaderVersion` and `UsbRomBoot` to bypass
the version check when the bootloader reports exactly `0.0.0`; unrelated
requests keep their version checks. Existing SDK libraries must be rebuilt
with `./scripts/bootstrap.sh` after updating this patch, then the app rebuilt.
Bootstrap refuses SDK source with the older unrestricted `OPAL_C1_PATCH`:
restore only its two request-version checks to upstream v2.30.0, preserving any
other SDK edits, before rerunning bootstrap.

## Tests

The camera-free safety regressions compile isolated C++ harnesses without
linking DepthAI or accessing USB:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_boot_safety.py'
```

The autofocus control regressions are offline: they inspect real serialized
DepthAI commands without enumerating or opening a camera. Enable the bridge test
targets, but build and run only the offline control test as shown below. Do not
run `bridge_test` or `region_test`: those access the camera.

```sh
cmake -S Sources/OpalBridge -B build/control-tests \
  -DOPAL_BRIDGE_TEST=ON
cmake --build build/control-tests --target control_delta_test
ctest --test-dir build/control-tests -R '^control_delta$' --output-on-failure
```

Check missing-camera discovery without accessing hardware or sending packets:

```sh
cmake --build build/control-tests --target usb_only_test
ctest --test-dir build/control-tests -R '^usb_only$' --output-on-failure
```

## The hardware

Little of this is documented elsewhere, so for the record:

- The C1 is a Luxonis DepthAI device: an Intel Movidius **Myriad X** VPU
  (USB VID `0x03E7`) paired with a Sony **IMX582** 48MP sensor (module name
  `LCM48`) and a real autofocus lens. Early units use a Sony **IMX378**.
- The sensor has **no native 1080p mode**. Its readout modes are
  3840×2160 (2–42 fps), 4000×3000 (2–30 fps), and 5312×6000 (1–10 fps).
  That's also why the app caps out at 42 fps.
- Full 4K NV12 at 30 fps is ~370 MB/s, which saturates USB 3 and costs
  ~300 ms of latency. So the app always captures 4K and downscales on the
  camera's ISP before the frame crosses the wire, which keeps
  glass-to-screen latency around 45 ms at 1080p30.
- The sensor is mounted upside down in the housing; the stock firmware
  compensates silently. A custom pipeline has to rotate on the ISP itself
  (`setImageOrientation`), or everything arrives inverted.
- Autofocus/auto-exposure regions are specified in **sensor** coordinates
  (3840×2160), not output coordinates — the depthai docs mention this, and
  getting it wrong pins every region into the top-left quadrant.
- The 3A loops (autofocus, auto-exposure, auto-white-balance) run on the
  camera, not the host.

## How it works

The C1's flash holds firmware that presents it as a standard UVC webcam —
that's why it works in any app with nothing installed. Open Opal takes the
camera over instead: it resets the VPU into its ROM bootloader, uploads the
~26 MB DepthAI firmware into the camera's **RAM**, and sends over a small
pipeline graph that the firmware instantiates on the VPU. Quitting reboots
the camera back to its stock firmware within a few seconds. Nothing is ever
written to flash, so the takeover can't brick anything. The app narrates
each stage live while connecting, with real sizes and timings.

For first-generation IMX378 C1s, the stock camera must present both video and
audio interfaces before Open Opal attempts the handoff. Every reconnect must
report the selected camera's MxID. If that ID disappears or changes, Open Opal
fails safely without uploading the pipeline, even if only one unbooted device
is attached. A USB address change is allowed; an unidentified device is not.

```
Myriad X (IMX582)
  ColorCamera ── ISP downscale ── NV12 ──► XLink/USB ──► OpalBridge (C shim over depthai-core)
  3A control  ◄─ XLinkIn ◄──────────────────────────────  CameraControl messages
                                                              │
                              IOSurface CVPixelBuffer ◄───────┘  (the only copy)
                                        │
              Metal: NV12 → linear RGB → mask → blur → composite
                                        │
                                 SwiftUI preview
```

The background blur uses Vision person segmentation, computed for the same
frame it masks (several frames are analysed concurrently to hold 30 fps),
then blurred in linear light so highlights bloom instead of greying out. An
optional depth-graded mode uses
[Depth Anything V2](https://huggingface.co/apple/coreml-depth-anything-v2-small)
for distance-based falloff.

### Autofocus

“Follow face” uses the upper-middle of the segmented person's box as an estimate
of where a face is, not a face detector. It refocuses when that area's size changes
by more than 40%, with a one-second cooldown. This works best with one person
facing the camera; raised arms or multiple people can confuse the estimate.

“Limit range” restricts autofocus to the Far and Near lens positions you choose
(0–255). The limit is restored after switching from manual to automatic focus,
changing autofocus mode, or focusing on a region. Turning the limit off restores
the full 0–255 range. Exposure and other unrelated control changes do not restart
autofocus. Entering manual focus clears the tracking history immediately, so
returning to automatic focus can refocus even if the person's size has not changed.

### Tuning files

Put one `.bin` ISP tuning file in `~/Library/Application Support/OpenOpal/tuning/`
to use it instead of DepthAI's defaults. It controls exposure, white balance,
colour and noise for one sensor and lens, so use one that matches your camera.
With several files, or none, the defaults are used.

### Virtual camera

Open Opal installs a CoreMediaIO system extension that publishes **"Open Opal
Camera"** to every app on the Mac. It carries the processed image, blur and all.
When the app isn't running it shows a camera-off symbol. The fallback contains
no text, so it stays understandable in mirrored self-views and in the normal
video other participants receive.

Virtual-camera output is always 1920×1080 BGRA, matching the extension's
advertised format. Other input sizes are scaled to fit with black bars rather
than stretched; native 1080p BGRA frames pass through without an extra copy.
The feeder uses the device's output scope and playback stream. The capture
stream serves camera clients and is not a queue for sending our frames.

**Start OpenOpal automatically** registers a small login helper that listens
for capture requests on "Open Opal Camera" and opens OpenOpal without taking
focus. It does not open the camera or process video. If macOS asks, allow
OpenOpal Launcher in **System Settings → General → Login Items & Extensions**.
Deliberately quitting during a call will not immediately relaunch it: turn the
meeting's camera off and on, or reopen OpenOpal, to start again.
