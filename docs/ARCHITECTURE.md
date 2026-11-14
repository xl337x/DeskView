# How DeskView works

## Processes
- One `powershell.exe` per PC runs DeskView (`app\DeskView.ps1` compiles `app\**\*.cs` with Add-Type and calls
  `DeskView.Program.Main`). Started at sign-in by `Startup\DeskView.lnk`.
- Video: one `ffmpeg.exe` per shared screen (sender), one `ffplay.exe` per picture shown (player). All tied to
  DeskView with a job object (they die with it). FFmpeg is the pinned build in `%LOCALAPPDATA%\DeskView\ffmpeg`.
- Optional "classic engine" (separate program + Windows service) - only when the user picks it. The default engine is
  DeskView's own (built-in), which needs nothing else.

## Roles
- **Server** = the computer whose keyboard and mouse are shared (normally the desktop with several monitors).
- **Client** = the other one (laptop). Both stream their screens and both can show the other's.
- Pairing code (8-12 chars, unambiguous alphabet) -> key for the link (HMAC handshake, per-session keys) and the
  video passphrase (`SHA256("DeskView-video-v2:" + code)`, first 16 bytes hex).

## Threads inside DeskView
- UI thread: WinForms. `Engine.Tick` every 250 ms (players, senders, smart screens, guide, files, reports) and a
  slow tick every 2 s (layout changes, discovery, layer order re-raise, portal re-check, names).
- Agent (`DeskViewAgent`, TCP 9002, on both PCs): accepts one authenticated controller session; a session thread
  per connection; applies input with SendInput, clipboard via an STA worker (`DvClip`), receives files.
- Forwarder (`DeskViewForwarder`, both PCs): low-level mouse/keyboard hooks on their own STA thread (+50 ms timer),
  a network thread (writes the queue, pings), a reader thread (agent replies).
- Discovery (UDP 9010): client finds the server by an HMAC-sealed broadcast probe.

## The link protocol (encrypted frames, one text message per frame)
Viewer/forwarder -> agent:
`E side along` enter at an edge · `R dx dy` relative move · `X` taken back · `M nx ny` absolute move (0..65535) on
the selected screen · `MS n nx ny` absolute move on screen n (several pictures) · `S n` select screen · `B b 0|1`
button · `W d`/`H d` wheel · `K vk scan ext down` key · `U` release everything · `CB/CD/CE` clipboard (base64
chunks) · `CQ` send me your clipboard · `P` ping · `N name` · `Q count` / `O 2,4` / `SR n:x,y,w,h;...` screen count,
screens holding windows, screen geometry · `RS n` restart your listener for screen n · `FILES` file session
(`F name len`, `D data`, `E`, `BYE`).
Agent -> viewer (prefixed `<`, anything else is refused as a reflection): `<V 2` version (sent first), `<L along`
pointer handed back, `<CB/CD/CE` clipboard, `<P` ping answer, `<SR ...` its screens, `<RS n`, `<DONE n` / `<ERR why`
(file session result).
Old peers ignore unknown messages; newer messages are only used after `<V 2` was seen.

## Input modes
- **Edge switching**: pointer pushed off the configured edge (`RemoteSide`) -> `E`; the local pointer is parked
  (hidden under a 1% "cloak" window) and relative motion is sent (`R`), keyboard goes along. Back across the side it
  came in -> `<L`. Not while a button is held (drag stays local).
- **Pictures** (server showing laptop screens on its monitors): absolute moves over a picture (`MS`), clicks over a
  picture go there; the keyboard follows a click into a picture (`KeysNeedClick`) and comes back with a click on the
  server. The guide strip (top 30 px) stays local. Client viewing a server screen full screen: keyboard follows.
- Keys are released where they were pressed (local/remote held sets), so modifiers never stick.

## Video pipeline
Sender: `ddagrab` (Desktop Duplication, output on the right adapter) -> GPU encoder (nvenc/qsv/amf/mf, else
libx264), `-g 30 -bf 0`, mpegts, SRT listener on 9000+n-1 (encrypted). A viewer connecting gets the stream; when it
leaves (or `RS`), the listener restarts.
Player: `ffplay` caller, `-fflags nobuffer`, `-vf setpts=N*0.001/TB` (always show the newest frame), `-autoexit`,
SRT `timeout=3 s` (dead stream ends it), `-nostats` (report stays small). Its window is adopted as a child of a
topmost
DeskView window (`DeskViewPictureHost`) - Windows refuses "always on top" for it otherwise. A picture is live when
its window shows (first frame); size/position come from the other computer's `SR` list.
Watchdogs: player exit -> restart (0.5/1/2 s back-off), 12 s without a picture -> retry, hung/lost window -> restart;
6 failures without ever a picture -> monitor given back with a notice.

## Smart screens (server)
Client reports which extra screens hold windows (`O`, every 500 ms on change, 5 s refresh). Server shows extra
screen n on monitor n-1 by itself; gives it back 3 s after it empties. A monitor the user gives back is left alone
until that screen is really empty for 5 s (link up). This memory (`SmartShown`, `SmartReleased`) is saved in
settings, so restarts don't grab monitors. A screen whose picture never comes is not retried for 5 minutes.

## Layers on a picture monitor (bottom -> top)
picture host -> drop zone (1% opacity, catches dragged files) -> guide strip + toast. Re-raised every 2 s.

## Setup flow (DeskView-Setup.ps1)
questions (role, code, extra screens - asked once) -> admin part only if something is missing (firewall LocalSubnet
rules, virtual display driver, optional classic engine) -> FFmpeg staged beside the running app (pinned zip, SHA256,
cached in %TEMP%, `-FFmpegZip` offline) -> stop DeskView -> copy (robocopy /MIR) -> swap FFmpeg by folder renames
(roll back on failure) -> `setup.json` hand-over -> start DeskView + Startup shortcut (in `finally`: DeskView is
always started again). Uninstall also removes the virtual screens DeskView installed (marker
`C:\VirtualDisplayDriver\deskview-cert.txt`), their driver and the certificate it trusted.
