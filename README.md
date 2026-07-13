# Open Opal

A native macOS app for the Opal C1 webcam. Opal has discontinued the C1 and its
Composer software; this project keeps the camera working.

The C1 is built on Luxonis' [DepthAI](https://github.com/luxonis/depthai-core)
platform, so it can be driven with open-source tools. Open Opal talks to the
camera directly over USB.

<img width="820" alt="Open Opal" src="docs/screenshot.png">

## Features

- Exposure: auto, or manual shutter and ISO, with EV compensation and AE lock
- Focus: autofocus modes, manual lens position, click anywhere to focus
- White balance: presets or manual Kelvin
- Anti-banding for 50/60 Hz lighting
- Sharpness, denoise, brightness, contrast, saturation
- 4K / 1080p / 720p, up to 42 fps
- Background blur, rendered in Metal with Apple's Vision segmentation
- Optional exposure metering on your face instead of the whole frame

Frames are downscaled on the camera's own ISP before crossing USB, which keeps
glass-to-screen latency around 45 ms at 1080p30. The toolbar shows the live
number.

## Building

Needs an Apple silicon Mac on macOS 26 or later, Xcode 26, and
`brew install cmake ninja xcodegen`.

```sh
./scripts/bootstrap.sh     # fetches and builds depthai-core
./scripts/fetch-models.sh  # downloads the Core ML depth model
xcodegen generate
open OpenOpal.xcodeproj
```

## How it works

The C1's flash contains firmware that presents it as a standard UVC webcam.
While Open Opal runs, the camera instead boots the DepthAI firmware in RAM,
streams NV12 frames over USB, and the app applies its processing in Metal on
the Mac. Quitting hands the camera back to its stock firmware within a few
seconds. Nothing is ever written to flash.

The background blur uses Vision person segmentation, masked per frame and
blurred in linear light. An optional depth-graded mode uses
[Depth Anything V2](https://huggingface.co/apple/coreml-depth-anything-v2-small)
for distance-based falloff.

## Status

Working: camera control, live preview, background blur.

Planned: a CoreMediaIO virtual camera, so the processed feed shows up in Zoom
and friends.

## License

MIT. Not affiliated with Opal Camera Inc. Thanks to Luxonis for DepthAI, and
to Opal for building the C1 on an open platform in the first place.
