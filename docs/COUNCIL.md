# Council: the plan for DeskView (2026-11-17)

Two rounds of independent critic agents (latency, input, logging; then core, video, control, security, displays),
two critics on round 2 (feasibility, product) and one judge. This is the judge's record; the reports themselves were
working notes. Check this file before re-proposing a mechanism.

## Owner's answers (2026-11-17)
1. "All systems" = **other operating systems** (macOS, Linux, more) - wanted, after the Windows desk works (R1-R4
   first, then Branch A below).
2. Input: **fix the built-in engine** (the classic engine only as a manual stopgap).
3. The video-key report fix (commit 34bf34c): push to `next` and test on the laptop.
Not answered yet (defaults from section 4 apply): two people at once, and the rest.

---


Inputs: round 1 (latency, input, logging, critic) and round 2 (core, video, input, security, displays, critic A,
critic B), checked against HEAD `34bf34c` and the pinned FFmpeg (`-h` only). Report names below are the file
names without `council-`/`council2-`.

**The judgement in one paragraph.** The owner has two Windows PCs and three pains: control that crosses, a
pointer and window that trail the hand, and video lag. All three can be fixed on the code we have, in weeks, with
no new runtime. Round 1 agreed this plan and none of it has landed yet (critic B). So the common core (R1-R4)
comes first and works for both readings of "all systems". The cross-OS branch starts only after the owner
answers question 1, and it begins by working with what exists (the classic engine mode, standard WebRTC), not by
building a second product. No new council round before R1 and R2 ship.

## 0. Rulings on the disagreements

| # | Dispute | Ruling | Reason (report) |
|---|---|---|---|
| 1 | Is 658 ms the real latency? | No. It was measured with the old player. Measure again before tuning | latency §0, critic §2 |
| 2 | VBV of one frame (latency) or 3-4 frames + `max_frame_size_i` (critic) | **Critic** | We keep an IDR every 0.5 s (two judge rulings). A one-frame budget would blur text twice a second |
| 3 | `-omit_video_pes_length 0` | A/B only, expect ~0. The default is `true` (checked), so the flag does change something | critic §2 |
| 4 | Intra refresh instead of GOP 30 | LATER | With `nobuffer`, the first picture depends on a key frame (critic) |
| 5 | Own D3D11 player (B1) | LATER, only if pacing is still bad after R2. The WebRTC spike may make it moot | critic, video |
| 6 | Own UDP+FEC transport (B2) | NEVER | Home-made crypto, no IDR on demand, needs B1 (critic, critic A) |
| 7 | Right Alt in the panic chord | Only when the layout maps nothing to AltGr+0 | `DeskView-Input.cs:1188-1191`: clearing `alt` on 0xA5 is deliberate, and AltGr+0 types `}` (critic) |
| 8 | Scroll Lock x3 as a panic | DROP | Most laptops have no Scroll Lock, and the client is a laptop (critic B). Use Numpad0 and the tray item |
| 9 | Server arbiter, per-target leases, or a local check | Local check now. Per-target leases only if R1 QA still finds crossings | input2 §1, critic A §2.3, critic B |
| 10 | Lease TTL 1.2 s | 3 s TTL, keep-alive every 500 ms, stop applying new input after 1 s, ReleaseAll at expiry, key-ups always applied | A Windows TCP retransmit plus Wi-Fi stalls exceed 1.2 s and would drop a drag (critic A) |
| 11 | Two people at once | Keep it as the default ("share"), with "yield" as an opt-in | input2 §1; round 1 DeskFocus would remove it without the owner agreeing |
| 12 | Binary TLV or text for v3 | Text inside the existing encrypted frame, one message registry, strict grammar | Text serves a second language just as well (critic A, critic B) |
| 13 | UDP for pointer motion | NEVER for now | Coalescing removes most head-of-line blocking (critic) |
| 14 | Round 1 logging: "secret leak via FFREPORT" | Stale. Fixed in `34bf34c` (`Media.cs:141-172` `StartReported`/`Redact`) | critic §4 |
| 15 | "Don't redirect stderr" | Overruled. The app now drains stderr on purpose | critic §4 |
| 16 | Event Log snapshot on every error | Read it only when the owner collects diagnostics | critic §4 |
| 17 | Media wire: SRT, WebRTC, or QUIC/libsrt keyed by TLS exporter | SRT now; a WebRTC (WHIP) spike with pass criteria; no QUIC; no exporter (.NET has none) | critic A §2.1, §3 |
| 18 | Spike length and timing (2 days vs 1 day after R2) | 2 days, after R2's numbers are in | Critic A's scope (mDNS rewrite, gather-complete) does not fit in 1 day; critic B's order holds |
| 19 | "One PeerConnection, BUNDLE, one UDP port" in phase 1 | False. One session per screen while ffmpeg drives it | critic A §1 |
| 20 | Random video key gives forward secrecy | No. It removes the offline target and the code from argv; the key itself is still on argv | critic A §3 |
| 21 | Custom ECDH (QW4) vs mutual TLS | Mutual TLS (SslStream) with pinned self-signed device certs, plus a code HMAC bound to the channel at pairing | Standard pieces beat our own crypto (critic A §2.5) |
| 22 | SAS / CPace in C# | LATER, in a second-language agent, with libraries | critic A |
| 23 | Window cut-outs now (displays) or later (critic B) | LATER, as an option. Whole screen stays the default | Cut-outs sit above every server window and stay out of Alt-Tab (critic B) |
| 24 | Predictive drag proxy | LATER, only if R2+R3 miss their numbers | A stale snapshot and a "pop" at drop are new jank (critic B) |
| 25 | Undocumented DPI-set call | DROP | critic A |
| 26 | Script-first macOS package (pwsh/python) | DROP | TCC would grant keystroke injection to the interpreter (critic A §2.4) |
| 27 | Rust or .NET second agent | Rust, with our own MIT backends, if the branch is taken | core §2; critic A |
| 28 | Bridge that speaks the classic engine's protocol | Try the existing classic engine mode first (zero code). Build the bridge only where its admin service is blocked. Never accept input from it | DeskView already drives the real engine (`CoreControl.cs`, critic A) |
| 29 | Cross-OS effort of 65-100 dev-days | Plan on 6-12 months of the owner's attention (+20% per critic A) | No mac/Linux machine in the QA loop (critic B) |
| 30 | "Pointer acceleration applied twice" (OPEN-ISSUES) | Wrong. It is applied once, with the local curve. The real issue is feel and lost sub-pixel motion | input §1, critic |
| 31 | Server described as "desktop, 3 monitors" | Wrong. It is a laptop-class PC using its panel, and one monitor hangs off a USB display adapter. Fix AGENTS.md (shapes only) | critic §0 |

## 1. Architecture decision (per layer)

| Layer | Decision |
|---|---|
| Control link + crypto | **Keep** today's TCP link (PBKDF2 code key, HMAC handshake, AES-CBC+HMAC frames, text messages). **R4:** split keys per direction, 12-char codes for new pairings, DPAPI for the stored code. **Cross-OS A1:** mutual TLS (SslStream, TLS 1.2+) with pinned self-signed device certs; code HMAC over the channel binding at pairing only; after the first v3 contact pin `min_proto=3` for that device. Never: our own ECDH, TLS exporters |
| Input / ownership | **Invent, small.** R1: local exclusion (a PC being driven cannot drive; a PC that drives answers `E` with `<L`), agent applies K/B/W/M only from its live driver, panic resets both PCs. **Spike if crossings remain:** `DvLease` per-target leases with epochs (pure C# 5 class, seeded simulator, 10k seeds, invariants I1-I4), timers as ruling 10. Raw mouse deltas LATER. Classic engine stays optional |
| Media transport | **Adopt SRT, tuned** (R2): latency 150->60-80 ms on Wi-Fi, 40->20 ms wired, after the burst fixes. **Spike WHIP/WebRTC** (ffmpeg `whip`, experimental) -> WebView2. Pass: glass-to-glass p95 <= 80 ms on Wi-Fi, 30 min without a drop, starts on the managed PC, no secret on argv, per-screen fallback to SRT works. Pass = WebRTC becomes the cross-OS media wire; fail = park it |
| Capture | **Adopt** ddagrab for whole screens at the shown monitor's real refresh rate (R3), `draw_mouse=0` once the cursor channel exists (R2). **Spike** `gfxcapture hwnd=` (occluded / on a virtual screen / off-desktop; Win10 border) for mirror mode when the virtual display driver is blocked |
| Cursor | **Invent:** a cursor channel on the link (`<C n x y shape`, coalesced, up to 120 Hz, shapes cached by hash); the viewer draws a click-through overlay and hides it while its own cursor drives. Exactly one pointer visible, always |
| Player / receiver | **Keep** ffplay inside our topmost host, with `SDL_RENDER_VSYNC=0`. WebView2 only if the spike passes. Own D3D11 player LATER |
| Virtual displays | **Keep** the current IddCx driver, **pinned and mirrored by SHA256** like FFmpeg; the trust import is explicit and opt-in; resolution and refresh copied from the monitor that shows each screen; mirror mode as the fallback. Never our own driver. Other-OS "rooms" LATER (private APIs) |
| Logging / diagnostics | **Invent** `app/Core/Diag.cs`: queue + background writer, UTC ms + monotonic time, level/component/thread, 5 x 1 MB rolling files, 2000-line flight recorder dumped on Error, rate limit per constant site key. `Input.cs`/`Portal.cs` stay standalone through a `Sink` delegate. System view: hook-death detector, `LowLevelHooksTimeout` at start, SystemEvents (lock, sleep, display change), per-process CPU/memory every 10 s, smoothness numbers (`-stats_period 10 -progress pipe:2` parsed; move inter-arrival histogram; player restarts and decode errors per minute), session id + clock offset over `P` (version-gated), collect-diagnostics zip with redaction, error counters in the main window |
| Discovery / pairing | **R4:** `DVD2` probe with a random nonce and no MAC, reply with a random install id and no machine name; broadcast stays primary. Cross-OS: DNS-SD as an add-on with a rotating blinded id; pairing = pinned device certs |

## 2. Roadmap

Rule: a release does not start before the previous one's numbers are in QA-LOG. Effort = code days, then the
calendar range with QA doubled (critic B). "Session" = one live test with the owner at both PCs.

### Common core (valid for both readings)

**R1 "Never crossed, and every error seen"**
- Scope: local exclusion; agent ownership check; panic chord LCtrl+LAlt+0 or Numpad0 (RAlt only when layout-safe),
  tray item "Bring everything back", `command.txt panic`, a version-gated panic message so both PCs reset, a
  toast on both screens; physical key bitmap instead of `GetAsyncKeyState`; re-hook while forwarding when no key
  is held; hook watchdog. Logger core (`Diag.cs`), routing of the ~15 meaningful empty catches, hook-death and
  SystemEvents lines, ffmpeg exit code + last 3 lines logged before a report is deleted.
- Touch points: `app/DeskView-Input.cs` (`TryEnter` ~1036, `Enter`/`Leave` ~564-589, message switch `X` 614 and
  K/B/W/M ~642, key hook 1183-1205, hook re-install ~855); `app/Core/Engine.cs` (`ShowOn("off")`, `Log` ~716);
  `app/Core/Program.cs` (handlers, sink); `app/Core/TrayApp.cs`; new `app/Core/Diag.cs`; `app/Core/Media.cs`
  (report delete); new `tests/focus.tests.ps1`, `tests/diag.tests.ps1`.
- Done when: 0 crossings in 200 scripted runs (B's touchpad on B's edge, simultaneous edges, view + edge);
  panic from either PC returns both to local in < 300 ms, and the pressed side in < 300 ms with the network
  unplugged; 0 stuck modifiers; German layout AltGr+0 still types `}`; log lines carry ms, nothing is deleted at
  2 MB; a test fails on any bare catch without a `// cleanup` comment; a simulated lost hook is detected in < 2 s.
- Live QA: 1-2 sessions (the owner's exact scenario, panic from each PC, Wi-Fi pulled mid-crossing).
- Effort: 4-6 code days, 1.5-2.5 weeks.

**R2 "The pointer feels local"**
- Scope: measuring rig first (240 fps phone camera, key-to-pixel harness, move inter-arrival histogram).
  Then: coalesce moves in `NetLoop` (last `MS` per screen, summed `R`, one write); cursor channel + overlay with
  `draw_mouse=0` (check the IddCx software-cursor trap first); nvenc `-delay 0 -surfaces` 1-4;
  `SDL_RENDER_VSYNC=0`; VBV of 3-4 frames + `-max_frame_size_i` + qsv `-low_delay_brc 1` (probe `low_power` in
  `TestEncoder`, fall back); Wi-Fi streaming mode via `WlanSetInterface` (log the return code); last, SRT latency
  down, with `discardcorrupt` off during the test so drops are counted. `-slices 4` and the PES flag as A/B only.
- Touch points: `app/Core/Media.cs` (`LatencyMs` 100, encoder args 192-196, capture string 202, player env 333,
  player args 347, `TestEncoder`); `app/DeskView-Input.cs` (`NetLoop` 864, queue 796, new `<C` message);
  new overlay window in `app/UI/`; `app/Core/Engine.cs` (Wi-Fi mode while a picture is live).
- Done when: pointer motion-to-photon p95 < 25 ms wired, < 40 ms Wi-Fi; exactly one pointer visible in every
  mode; move inter-arrival p95 < 20 ms, no gap > 100 ms in a 10 s drag; content key-to-pixel p50 < 150 ms wired /
  < 200 ms Wi-Fi, p95 < 250 ms; < 1 % repeated or skipped frames in a constant-speed slide, no hitch every 0.5 s;
  decode errors per minute no worse than before the latency change.
- Live QA: 2 sessions (camera on both screens; optional MWB baseline on the same pair if policy allows).
- Effort: 7-12 code days, 3-5 weeks.

**Spike S1 (after R2): WHIP to WebView2**, 2 days, pass criteria in section 1. Pinned, SHA256-checked WebView2
SDK; random loopback port with a one-time path token, bound before ffmpeg starts; mDNS candidate rewrite;
answer after gathering completes. Live QA: 1 session.

**R3 "A dragged window lands at once"**
- Scope: each virtual screen copies the resolution and refresh of the monitor that shows it (from `SR`); capture
  at that rate (`dmDisplayFrequency`); pre-warm the player on `MOVESIZESTART`; "my sender restarted" notice to
  the viewer (guarded against restarting a player that just connected); smart screens remember where each screen
  was last put; pin and mirror the driver; mirror mode when the driver is blocked.
- Touch points: `app/DeskView-Displays.cs` (`Arrange(1920,1080,...)`, refresh struct ~18);
  `app/DeskView-Setup.ps1` (driver source, trust import prompt); `app/Core/Engine.cs` (smart screens, pre-warm);
  `app/Core/Media.cs` (framerate, restart notice).
- Done when: a window dropped on an extra screen shows on the server monitor < 300 ms after release, never on a
  blank monitor ("connecting" instead); a killed sender freezes the picture < 1 s; the driver install is
  hash-checked; with the USB-adapter monitor, a local drag with DeskView off is filmed as the floor.
- Live QA: 1-2 sessions. Effort: 4-6 code days, 2-3 weeks.

**R4 "Safe to leave on at work"**
- Scope: random per-session video key sent over the link (`VK n`), rotated on every listener restart; discovery
  without verifier or name; 12-char codes for new pairings (rejection sampling); per-direction keys; DPAPI for the
  stored code; received files get Mark-of-the-Web, a quota and a first-time prompt per device; clipboard skips
  password-manager copies (exclusion formats). Diagnostics: collect zip (both PCs, redacted), clock offset,
  merge-logs tool, status line.
- Touch points: `app/Core/AppSettings.cs` (`VideoKey`, code storage); `app/Core/Media.cs` 200/325;
  `app/DeskView-Input.cs` (`DvProto` ~191-299, handshake ~416-442, discovery ~1277-1320, `SafeTarget` 532,
  `DvClip` 119); `app/DeskView-Setup.ps1` (new code length); `app/Core/Diag.cs`; `tests/tools/merge-logs.ps1`.
- Done when: no code-derived value on any argv, in any report or on the wire as a verifier (tests grep argv and
  captures); discovery replies carry no name; 8-11 char codes refused for new pairings and warned for old ones;
  received files carry `Zone.Identifier`; a password-manager copy is not synced; the redaction fixture test
  passes; both logs merge to within one RTT. Owner re-pairs once.
- Live QA: 1 session. Effort: 3-5 code days, 1.5-2.5 weeks.

Common core total: about 18-29 code days, 2-3.5 months of calendar, 6-8 owner sessions.

### Branch B: "alongside all systems" = coexisting with other tools (if question 1 = b)

**R5b "Plays well with others"**: detect other input sharers (MWB, the classic engine's service, vendor mouse
software) and refuse to arm edges or hotkeys that clash, saying why; offer to remove the idle classic-engine
service; survive display hot-plug, docks, USB display adapters and other virtual display drivers; check hotkeys
against what is already registered. Touch points: `Engine.cs`, `DeskView-Displays.cs`, `DeskView-Setup.ps1`,
`CoreControl.cs`. Done when: with each tool running, DeskView warns and never forwards twice; 0 crashes in 20
hot-plug cycles. 1-2 sessions; 3-5 code days, 2-3 weeks.

### Branch A: other operating systems (if question 1 = a, and a mac or Linux machine is on the desk)

- **A1 Spec and link (3-4 weeks):** `docs/PROTOCOL.md` with one message registry, strict text grammar, golden
  transcripts in `tests/protocol/`; v3 additions (HID keys as u32 page:usage, `CAP`/`OS` bound into the
  transcript, MIME clipboard list, `MD` media descriptor); mutual TLS link; the leases from the spike. Done when:
  C# passes all vectors; v2 peers still work; a v3 peer refuses a v2 downgrade.
- **A2 Use what exists (1-2 weeks):** the classic engine mode drives the other OS's input; the bridge only if its
  service is blocked. Viewer of Windows screens on the other OS via WebRTC (if S1 passed) or ffplay. Done when:
  keyboard, mouse and text clipboard work both ways for a day of normal use.
- **A3 Native agent (months):** Rust, own MIT backends, macOS + X11 first, local-cert signing on macOS (no paid
  ID by default), then GNOME/KDE Wayland via portals. Done when: the agent passes the same vectors and a 200-run
  crossing test on mixed OSes.
- **A4 Other-OS virtual displays and per-window streams:** LATER, private APIs.
Effort: 6-12 months of the owner's attention; dozens of sessions on hardware not owned today.

## 3. Decision log

Rulings in section 0 are part of this log; the rows below cover the rest.

| Proposal | Verdict | Reason |
|---|---|---|
| Camera rig, per-stage re-measure | NOW (R2) | Every number is a guess until then |
| Move coalescing; cursor channel + overlay | NOW (R2) | Bursts gone; one pointer, the biggest felt gain |
| nvenc `-delay 0`, `SDL_RENDER_VSYNC=0`, VBV 3-4 frames + I-frame cap, Wi-Fi streaming mode | NOW (R2) | Flags verified, cheap |
| SRT latency down | NOW (R2, last) | Only after bursts are gone; count drops |
| `omit_video_pes_length 0`, `-slices 4` | SPIKE (A/B) | Gains unsure |
| WHIP/WebRTC + WebView2 | SPIKE (S1) | Could remove the SRT hold and the argv key |
| Local exclusion, ownership check, two-sided panic, key bitmap, re-hook, watchdog | NOW (R1) | Closes the reported bug |
| Per-target leases + epochs + simulator | SPIKE | Only if R1 QA finds crossings |
| Server-as-arbiter single focus | NEVER | Single point of failure, removes two-people use |
| Raw mouse deltas | LATER | Feel, not smoothness |
| Separate bulk connection, lazy clipboard, file resume | LATER (A1) | Real, not urgent for 2 PCs |
| Logger core, catches, hook-death, SystemEvents | NOW (R1) | Owner asked; needed to prove R1-R3 |
| Smoothness metrics in logs | NOW (R2) | Error counts alone don't diagnose jank |
| Collect zip, clock offset, status line | NOW (R4) | One command, both sides |
| Perf counters, ETW | NEVER | Slow, need admin |
| Per-session video key, discovery fix, 12-char codes, split keys, DPAPI, MOTW/quota, clipboard exclusion | NOW (R4) | Cheap, closes off-box leaks |
| Mutual TLS with pinned device certs; device keys, trust store, capabilities | LATER (A1) | Right for N devices; standard pieces |
| Match virtual screen to its monitor, pre-warm, restart notice, pin the driver | NOW (R3) | Drops land at once; driver unpinned today |
| Per-window `gfxcapture` | SPIKE | Mirror-mode fallback first |
| Our own display driver | NEVER | EV cert + attestation |
| Rust agent, Wayland, macOS | LATER (A3) | No test hardware yet |
| Browser viewer / tablets as screens | LATER | Free tools already do it |
| iPad input, internet relay | NEVER | No injection API; use an overlay VPN |
| Another council round | NEVER before R1+R2 ship | Reports outnumber fixes |

## 4. Questions for the owner (with the default if he doesn't answer)

1. **"Works alongside all systems": other operating systems, or coexisting with other tools on your PCs?**
   Default: coexisting (branch B) after R4. Other OSes only once a mac or Linux machine is on the desk.
2. **Use the classic engine as the input default, or fix the built-in engine?** Default: fix the built-in engine
   (R1 is days, and "without the classic engine" is a standing goal). If crossing hurts before R1 ships, the
   classic engine mode can be switched on by hand as a stopgap; it cannot cross (one primary) but needs its admin
   service.
3. **Two people at once (each PC used by its own person while pictures show)?** Default: keep it ("share"),
   with an opt-in "yield" that blocks local input while driven.
4. **Panic chord** = Ctrl+Alt+0 (left Alt) or Ctrl+Alt+Numpad0, plus the tray item, shown on the guide strip at
   every crossing? Default: yes.
5. **Can the WebView2 spike download a pinned Microsoft SDK?** Default: yes, spike only, removed if it fails.
6. **Virtual display driver on the managed PC:** ask before the trust import every time? Default: ask; fall back
   to mirror mode if refused.
7. **Push `34bf34c` now?** Default: push to `next` after OPEN-ISSUES #0 is checked live, then change the pairing
   code on both PCs; re-pair once more with a 12-char code after R4.
8. **May we test MWB once on the same pair as a "feel" baseline?** Default: only if company policy allows.
9. **If branch A: own MIT backends or GPL-3 parts; pay for an Apple developer ID?** Default: own MIT backends;
   no paid ID (local-cert signing).

## 5. Top risks and how we see them early

| Risk | Early signal (log / metric) |
|---|---|
| Crossings survive the local check | `focus` log lines "edge refused: being driven"; simulator seeds; 200-run scripted test in R1 |
| Windows silently drops the hook while forwarding (panic dead) | Hook-death counter in `Diag`; `LowLevelHooksTimeout` logged at start; callback times > 50 ms |
| Lower SRT latency causes broken frames on Wi-Fi | Decode errors per minute in the player report (test without `discardcorrupt`); restarts per hour |
| Overlay shows two pointers (cursor baked in by the virtual display) | Test sender with `draw_mouse=0` before writing the overlay; camera count of visible pointers |
| Encoder flags unsupported on an older iGPU | `TestEncoder` probe result and fallback line in the log at start |
| Policy refuses Wi-Fi mode, driver trust or WebView2 | Return codes logged; setup output says which fallback is used |
| The USB-adapter monitor is the real floor | Filmed local drag with DeskView off (R3) |
| WHIP interop fails or restarts | Spike log separates "ICE failed" from "DTLS failed"; 30-min run |
| Scope creep into the cross-OS branch | Release gate: QA-LOG numbers before the next release; count owner sessions per release |
| Secrets reach company telemetry | Test that greps every argv and report for code-derived values (R4) |
| Leases (if added) drop control mid-drag | Lease-expiry counter vs measured p99 link gap |
