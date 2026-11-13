# Third-party notices

DeskView uses the following separately licensed components. They are installed alongside DeskView, not part of
this repository's MIT-licensed code.

## Keyboard/mouse engine

A modified build of the Deskflow project, licensed under the GNU General Public License v2.0 (with the OpenSSL
exception). The complete source code of the build DeskView uses, including DeskView's changes (portals), is
available at https://github.com/xl337x/deskflow (branch `deskview`). Licence text: see `LICENSE` in that repository.

## FFmpeg

Video capture, encoding and playback use FFmpeg (https://ffmpeg.org), licensed under the GNU LGPL / GPL depending
on the build. DeskView runs the FFmpeg programs; it does not include FFmpeg's code.

## Virtual Display Driver (optional)

Extra virtual screens use the Virtual Display Driver (https://github.com/VirtualDrivers/Virtual-Display-Driver),
MIT licensed, installed only when requested.
