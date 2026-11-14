# Third-party notices

DeskView's own code (this repository) is MIT licensed. It runs alongside these separately licensed components,
which are not part of this repository's code.

## FFmpeg

Video capture, encoding and playback use the FFmpeg programs `ffmpeg.exe` and `ffplay.exe` (https://ffmpeg.org).
The installer downloads one pinned Windows build, `ffmpeg-n9.0.2-57-gd838f9f9ae-win64-gpl-shared-9.0.zip`
(SHA256 `f4e068477787394da18a44b27d3e2cb19e05b21495b836a4fd5a31958b608932`), made by
https://github.com/BtbN/FFmpeg-Builds and mirrored unchanged as the release asset
https://github.com/xl337x/DeskView/releases/tag/deps-ffmpeg-9.0. That build is licensed under the GNU GPL v3.
Its corresponding source code: FFmpeg n9.0.2-57-gd838f9f9ae at https://github.com/FFmpeg/FFmpeg, and the build
scripts and library versions at https://github.com/BtbN/FFmpeg-Builds. DeskView only starts these programs; it does
not include or link FFmpeg's code.

## Classic keyboard/mouse engine (optional)

DeskView has its own keyboard/mouse switching. Optionally (installer switch `-ClassicEngine`) it can drive a
separately installed open-source keyboard/mouse sharing engine, licensed under the GNU GPL v2.0. That engine is
installed from its publisher's own package; DeskView does not distribute it.

## Virtual Display Driver (optional)

Extra virtual screens use the Virtual Display Driver (https://github.com/VirtualDrivers/Virtual-Display-Driver),
MIT licensed, installed from its publisher's package only when requested (`-VirtualScreens N`).
