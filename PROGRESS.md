# Progress

Last updated: 2026-07-30

## Done

**System section (`SystemAudioController.swift`)** — global controls in the
menu, above the per-app "Applications" list (SoundSource-style header +
divider for each group). Popover sizing changed in the later HIG-polish
session below — see that entry for the current (300pt-wide,
height-now-variable-up-to-a-cap) behavior.
- **OUTPUT** / **INPUT** rows: `SystemDeviceVolumeController`, one instance
  per kind. Reads/writes `kAudioDevicePropertyVolumeScalar` on the current
  default output/input device, live-synced both ways: a property listener
  reflects hardware media-key changes into the slider (confirmed live), and
  dragging the slider writes straight through. Both rows are 0–100% — OUTPUT
  briefly supported 0–200% boost (a second `.allExcluding` tap layered on
  top of everything else hitting the device, targeting the exact
  `AudioObjectID` this row reads/writes hardware volume on) but it was
  removed again in a later session, at the user's request, before ever being
  confirmed working by ear; see the `SystemDeviceVolumeController` class doc
  comment in `SystemAudioController.swift` for the gotcha a future attempt
  should know about (a tap
  Sori's already individually rendering for some app is attributed to
  Sori's own PID at the HAL level, so `.allExcluding([ownProcessObjectID])`
  silently skips boosting anything already gain-adjusted or redirected).
  Both rows also got device pickers (`SystemDeviceMenu`) that write
  `kAudioHardwarePropertyDefaultOutputDevice`/`DefaultInputDevice` directly —
  implemented, still not yet clicked-through and confirmed live (see Known
  gaps).
  `HardwareVolumeAddressing` handles devices that only expose per-channel
  volume controls, no master element at all (confirmed live: true of both
  output devices on this machine — only the input device happened to expose
  a real master element) — averages/sets across whichever channels exist.
  Also re-subscribes automatically if the default device itself changes.
  Input row greys out and disables if the current device has no settable
  volume property at all.
- **SOUND EFFECTS** row: `SystemAlertVolumeController`. macOS's alert/UI
  sound volume is **not** a Core Audio HAL property — confirmed live by
  diffing every single `defaults` preference domain on the machine (~40 of
  them) before/after changing it via `osascript -e 'set volume alert volume
  N'` (zero domains changed, ruling out the older documented
  `com.apple.sound.beep.volume` mechanism), and by reading
  `kAudioDevicePropertyVolumeScalar` directly on the actual default *system*
  output device and finding it holds a completely different, independently
  moving value. It's private, non-persisted, coreaudiod-internal state with
  no discoverable `AudioObjectID` selector (grepped the CoreAudio /
  AudioToolbox / AudioHardwareService headers and exported symbols for this
  SDK — nothing). The only stable, Apple-supported, working surface found is
  the Standard Additions `set volume alert volume` / `get volume settings`
  AppleScript command pair (same thing System Settings' Sound pane and
  `osascript` itself use) — driven via in-process `NSAppleScript` rather than
  shelling out, so a slider drag doesn't spawn a process per tick. No
  listener exists for it either, so external changes are caught by its own
  1s poll (independent of `AudioProcessMonitor`'s, which was later tightened
  to 250ms — see Block B below; this one wasn't). Confirmed live: dragging
  the slider audibly changes system alert/beep loudness, independent of main
  output volume.

**Permission & app shell**
- MenuBarExtra agent app (LSUIElement, no dock icon, no main window), signed
  with a real Development Team so TCC prompts fire correctly.
- `AudioRecordingPermission` — TCC SPI check/request for `kTCCServiceAudioCapture`,
  wired to a "Grant permission" button / "granted" status line in the dropdown.
- "Quit Sori" button at the bottom of the dropdown (`NSApplication.shared.terminate(nil)`)
  — needed since an `LSUIElement` app has no dock icon and therefore no
  standard quit path otherwise. Confirmed live: quits cleanly, no leftover
  process.

**Tap engine (`ProcessAudioTapEngine`)**
- Core Audio process tap → private aggregate device → `AudioDeviceCreateIOProcIDWithBlock`
  IO, no `AVAudioEngine`. Two target modes: `.allExcluding` (whole-system minus
  self, for diagnostics) and `.only` (exactly one app's current PIDs, for
  volume control — this is the one real usage relies on).
- Gain 0.0–2.0 applied per-sample. Boost (>1.0) runs through a tanh soft-knee
  limiter (transparent below 0.9 amplitude) so boosted samples don't hard-clip;
  logs "Limiter ENGAGED/not engaged" ~1/sec while boosted.
- Exact teardown order established and followed everywhere:
  `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
  `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
- Handles `kAudioHardwareIllegalOperationError` (stale aggregate) by tearing
  down and recreating once.

**Process enumeration & resolution (`AudioProcessMonitor`)**
- Polls `kAudioHardwarePropertyProcessObjectList` every 250ms (tightened
  from 1s in the Block B session — see "Block B" below), filters to
  `kAudioProcessPropertyIsRunningOutput == true`, groups PIDs by *owning app*
  (not raw bundle id — Chrome/Discord-style helpers have distinct per-helper
  bundle ids that don't naturally collapse).
- 4-layer resolution chain, each layer added to fix a real live-tested case:
  direct `NSRunningApplication` bundle → WebKit name-suffix match (Safari/any
  WebKit-embedding app's shared, launchd-spawned GPU/WebContent XPC service) →
  parent-process-chain walk → `proc_pidpath()` + bundle-path climb (Discord's
  `posix_spawn`ed audio helper, never LaunchServices-registered).
- Cross-checks resolved bundle ids against `NSWorkspace.runningApplications`
  so a background daemon merely *packaged* as an `.app` (Rogue Amoeba's ARK
  driver agent) doesn't get mistaken for a user-facing app.

**Per-app volume UI (`AppVolumeController` + `SoriApp.swift`)**
- One row per app: icon, name, live-updating %, mute button, slider (0–200%,
  snaps to exactly 100% within a small drag window).
- `.menuBarExtraStyle(.window)` (not `.menu` — confirmed live that `.menu`
  can't host a draggable `Slider`), fixed 280×360 size with the app list in a
  `ScrollView` (confirmed live that `.window` doesn't reliably resize for
  background-driven content changes — this was mistaken for a "second app
  replaces the first" data bug before the real cause was found).
- Tap engine created lazily per app, only while `effectiveGain != 1.0`;
  torn down when gain returns to 1.0 or the app goes silent (`pids: []`).
- Gain + mute persist to UserDefaults per bundle id, survive Sori relaunches.
- List membership is broader than "has an active tap": a row also stays
  (dimmed) if the app was ever seen active this session, or the user ever
  touched its slider/mute this session (both in-memory only, reset on
  relaunch), or it has a persisted non-default setting from a prior launch.
  Two related bugs found and fixed live: a slider drag through the exact
  100% snap point momentarily failing every pin criterion and yanking the
  row away mid-drag; and a first-attempt time-limited (5s) interaction grace
  period that just delayed the same disappearance instead of preventing it —
  replaced with a permanent-for-the-session flag.

**Docs**
- `CLAUDE.md` written this session with the above traps in detail.

**Block B — per-app audio redirection (`AvailableAudioDevices`,
`SoriOwnedAggregateDevices`, redirect additions to `AppVolumeController` and
`ProcessAudioTapEngine`)**
- Each app row gets a "Redirect Audio To" menu (`RedirectDeviceMenu`) —
  pick "No Redirect" or any connected output device. Icon is filled+normal
  when the redirect target is connected, outline at "No Redirect", and
  filled+orange with a tooltip when the target is set but currently
  disconnected (`isRedirectPending`) - a glance-able state, not just detail
  buried inside the opened menu.
  `ProcessAudioTapEngine` gained an `outputDevice` override param so a
  redirect just points the same tap machinery at an explicit device instead
  of the default (this was also used by the System section's since-removed
  OUTPUT boost tap - see above). `AvailableAudioDevices` is the shared,
  live-updating (property-listener-driven) list of connected output/input
  devices behind both this picker and the System section's device pickers.
- Redirect choice persists per bundle id (UID + last-known display name, so
  a disconnected target shows "(unavailable)" instead of silently looking
  reset) and survives relaunch, same mechanism as gain/mute.
- **Device hot-plug fully verified live** (own session, after the items
  below): if a redirect target disconnects mid-playback, the app falls back
  to system output automatically (confirmed: teardown + rebuild targeting
  the live default device, 23.7ms gap, logged); reconnecting restores the
  redirect automatically (confirmed both audibly and in the log, including
  across the device getting a brand-new `AudioObjectID` on reconnect); an
  app redirected elsewhere or not redirected at all stays untouched during
  someone else's transition (confirmed: `com.apple.Music`, redirected to the
  same now-vanished device but idle, correctly no-op'd rather than following
  Safari's rebuild); and relaunching with the target still disconnected
  resolves the redirect to "not currently applicable" cleanly (`target
  unchanged (nil) - no-op`, no crash) while `defaults read` confirms the
  underlying choice itself is untouched on disk. This falls out almost for
  free from the existing lazy-tap logic (`effectiveRedirectDeviceID`
  resolves to `nil` when the UID isn't currently connected) rather than
  being special-cased - the only new code was cosmetic (the pending-state
  icon above) and clearer reason-string logging to make the verification
  itself legible.
- **A real, confirmed-live bug was found and fixed here**: redirecting an
  app produced a repeating cycle (audio briefly on the redirect target, cut
  out, briefly on system default, repeat, forever, once a second). Root
  cause: a private aggregate device is invisible to *other* processes
  enumerating `kAudioHardwarePropertyDevices` but IS visible to its own
  creating process (confirmed live, now documented as CLAUDE.md trap #19) —
  so every tap rebuild's freshly-UUID-named aggregate looked like a "new
  device" to `AvailableAudioDevices`, which triggered every app's redirect
  target to re-resolve, which rebuilt the tap, which created another new
  aggregate UUID, forever. Fixed two ways: `SoriOwnedAggregateDevices`
  tracks Sori's own aggregate UIDs and filters them out of enumeration, and
  `AppVolumeController.refreshTapForRedirectChange` now compares the
  specific applied-vs-effective redirect target and no-ops unless it
  actually changed (was unconditional before). A rebuild-loop guard (5
  rebuilds/10s trips a loud logged warning and suppresses further automatic
  rebuilds) was added as defense in depth against a similar bug recurring.
  Confirmed live after the fix: single clean aggregate create per real
  state change, zero spurious rebuilds, loop guard stayed silent.
- **Poll interval tightened 1s → 250ms** to shrink the window where a
  redirected/gain-adjusted app's audio plays unmanaged on the system default
  before the tap engages (this is inherent to detecting "audio started" via
  polling rather than being told immediately — see Known gaps). Cut the
  worst-case leak window from ~1.0s to ~0.25s (tap engagement itself is a
  consistent ~15-40ms on top, measured both before and after). Measured
  cost: ~1.3% → ~4.4% average CPU for the whole app, live-sampled via `top`.
- Investigated live whether event-driven detection could replace polling
  entirely (register listeners on `kAudioHardwarePropertyProcessObjectList`
  and per-process `kAudioProcessPropertyIsRunningOutput` instead of
  polling). `ProcessObjectList` fires reliably; `IsRunningOutput` **never
  fired once** across three separate live tests, confirmed via a
  precisely-timed controlled test where the value necessarily changed. Full
  writeup in CLAUDE.md trap #20. Kept polling as a result.

**HIG-native UI polish pass (`SoriApp.swift`)** — requested explicitly as a
"make it look like a first-party Apple menu bar app" pass, following the
macOS Human Interface Guidelines rather than a custom visual language.
- Background switched from a flat fill to `.regularMaterial` (blurs like a
  native menu; automatically respects Reduce Transparency/Increase Contrast,
  no extra accessibility code needed) with a continuous 12pt corner radius.
- Typography switched to system fonts at standard sizes throughout (`.body`
  rows, `.caption`/`.caption2` for secondary info and section headers) - no
  `.custom()`, no named "SF Pro."
- Menu bar icon replaced: the stock `"waveform"` SF Symbol is now a custom
  3-bar "equalizer" mark, distinctive from the generic sine-wave glyph.
  Built as a template `NSImage` drawn programmatically at launch
  (`NSImage(size:flipped:drawingHandler:)` + `isTemplate = true`) rather than
  an Assets.xcassets entry, so there's no xcodegen/asset-catalog step to
  keep in sync - `isTemplate` is what makes AppKit auto-tint it correctly
  for light/dark menu bars and menu bar tinting, same as a stock SF Symbol.
- Dimmed-state treatments replaced with values that map to real AppKit
  conventions instead of an invented "45% opacity" used everywhere
  previously: pinned-inactive app rows now use `.foregroundStyle(.secondary)`
  for text (the actual native way to de-emphasize text) and 50% icon opacity
  specifically (matching AppKit's own conventional dimmed-icon treatment,
  e.g. Finder's cut/hidden-item icons - not arbitrary). The disabled INPUT
  row no longer has a manual opacity multiplier at all - it now relies
  entirely on the Slider's own native disabled-control styling.
- Per-app rows: boost territory (gain > 100%) now gets a subtle system
  orange tint on the slider and percentage text, so 100%-200% doesn't look
  identical to 0%-100%. System OUTPUT already lost its boost region in an
  earlier session, so its slider is a plain 0-100% track with 100% at the
  far right, not a truncated-looking half of a wider range.
- Quit moved from a left-aligned plain-text button to a full-width row
  styled like a native menu item (primary text color, standard row padding,
  no button chrome), with ⌘Q added via `.keyboardShortcut` - **not yet
  confirmed live whether the shortcut actually fires** from a
  `.window`-style MenuBarExtra popover (deferred to next session, see Known
  gaps).
- Popover width fixed at 300pt (widened from 280pt for breathing room around
  the per-app row's five controls). Height, previously a hard-coded
  280×360-derived constant, was changed to size to content up to
  `maxVisibleApps` (5) rows, only scrolling past that cap - this directly
  re-tests CLAUDE.md trap #12 ("`MenuBarExtra(.window)` doesn't reliably
  resize when content grows from a background update," confirmed live on an
  earlier macOS build). **The live re-test itself has not happened yet**
  (deferred to next session) - see Known gaps.

**Launch at Login + gear settings menu (`LaunchAtLoginController`,
`SoriApp.swift`)** — requested as two related asks: add a "Launch 소리 at
Login" option via the modern `SMAppService` API, then pull app-level chrome
out of the main popover entirely so it's purely audio controls.
- `LaunchAtLoginController` wraps `SMAppService.mainApp` — default OFF
  (nothing registers itself without the user opting in), `register()`/
  `unregister()` on toggle, `status` re-read via `refreshStatus()` rather
  than cached, since the system (not Sori) is the source of truth if the
  user removes/pauses it directly in System Settings. `.requiresApproval`
  still reads as "on" for the toggle, with a menu item to jump straight to
  System Settings via `SMAppService.openSystemSettingsLoginItems()` (the
  officially supported deep link, not a hand-built URL scheme).
- Main popover restructured to hold only System + Applications — the
  audio-permission status line and the Launch-at-Login toggle both moved
  behind a small `gearshape` icon (`SettingsMenu`), a real SwiftUI `Menu` so
  the toggle renders as a native checkable `NSMenuItem`. **Exception, per
  explicit request**: permission status is only quiet/tucked-away once
  *granted* — if it's missing/denied/unknown, a loud orange-tinted
  `PermissionRequiredBanner` with a prominent "Grant Audio Permission…"
  button stays on the main surface instead, since the app can't function at
  all without it.
- Gear icon iterated per live user feedback across a few rounds: started
  top-right of a dedicated header row, then moved onto the same footer row
  as "Quit Sori" (trailing-aligned via `Spacer()`) per user request so both
  non-audio controls share one predictable place; the menu's default
  disclosure chevron was then removed (`.menuIndicator(.hidden)`, macOS 14+)
  and the icon nudged right (`.offset(x: 6)`) to close the dead space that
  left behind. Quit itself deliberately was **not** folded into the gear
  menu — it already has a confirmed-live ⌘Q shortcut as a plain footer
  button, and nesting it inside the settings `Menu` risked that keyEquivalent
  only firing while the submenu itself is open rather than whenever the
  popover is.
- Menu bar icon rendering was independently re-confirmed live this session
  via a tightly-cropped (not full-screen) screenshot: three rounded bars,
  short/tall/medium, matching the `[8, 15, 11]` heights in code.
- **Not yet done: the actual functional verification this feature was built
  for.** Toggling it on/off and confirming it actually appears/disappears
  from System Settings > General > Login Items & Extensions was the
  original ask, but the session got pulled into UI-layout iteration
  (gear placement, arrow, offset) before that ground-truth check happened.
  Do this first next session - see Known gaps and Next.

**Crash diagnosis and fix (2026-07-30)** — user-reported "Sori randomly quits
after running for a while during normal use." Diagnosed from the one real
crash report on this machine, `~/Library/Logs/DiagnosticReports/Retired/
sori-2026-07-27-193913.ips`, before changing anything.
- Root cause found directly from the crash report's own symbolicated stack:
  `EXC_BREAKPOINT`/`SIGTRAP` (a Swift runtime trap, not memory corruption),
  on the **main thread**, top frame `AudioProcessMonitor.refresh()` at the
  `Dictionary(uniqueKeysWithValues:)` call building `runningAppsByPID`.
  `NSRunningApplication.processIdentifier` returns `-1` for an app
  transitioning in/out of existence; two such apps in the same 250ms poll
  tick produced a duplicate `-1` key and the initializer fatal-trapped. None
  of the Core Audio/IOProc/teardown-race hypotheses that prompted the
  investigation were actually implicated - nowhere near the realtime thread.
- Fixed by filtering `pid <= 0` entries before constructing the dictionary,
  then adding `uniquingKeysWith:` (first-wins) as defense-in-depth, matching
  the existing `runningAppsByName` pattern. Documented as CLAUDE.md's new
  "Crash resilience & permission-flow notes" section.
- Audited the whole codebase for the same class of bug (every other
  `Dictionary`/`Set` construction fed by live OS enumeration, every
  force-unwrap, `as!`, `try!`, `fatalError`, `precondition`) - this was the
  only instance found.
- `SoriDebugLog` (tap/aggregate/IOProc/device-list/rebuild lifecycle
  logging) changed from stderr-only-behind-an-env-var to **always** writing
  to a persistent `~/Library/Logs/Sori/sori.log` (5MB rotation, one backup),
  so a future intermittent crash leaves a trail instead of needing to be
  anticipated in advance. Confirmed no call site is reached from the
  realtime IOProc callback before making this change.
- Build verified clean after each change (`xcodebuild` → BUILD SUCCEEDED).

**Permission-required banner fixes (2026-07-30)** — two bugs reported live:
message text truncating instead of wrapping, and the "Grant Audio
Permission" button appearing dead after a permission revocation.
- Text truncation fixed with `.fixedSize(horizontal: false, vertical: true)`
  on both the warning text and the new denied-state helper text - without
  it, the `Text` was collapsing to a single-line ideal width inside the
  fixed 300pt popover instead of wrapping.
- The dead-button issue turned out to be expected macOS TCC behavior, not a
  wiring bug: once any decision is recorded for `kTCCServiceAudioCapture`
  (`.denied` - covers both an initial refusal and a later revocation),
  `TCCAccessRequest` silently replays that decision and never shows the
  consent dialog again. `PermissionRequiredBanner` now branches on
  `permission.status`: `.unknown` still calls `request()` (the real prompt);
  `.denied` instead opens System Settings directly via
  `AudioRecordingPermission.openSystemSettingsPrivacyPane()`
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  - confirmed correct via Apple's own support documentation, since system
  audio recording shares a pane with Screen Recording), with copy explaining
  the user needs to fully quit and reopen Sori afterward - Apple's own
  guidance for that pane says toggling the switch doesn't take effect
  otherwise. Documented in CLAUDE.md.

**GitHub repo made public (2026-07-30)** — `github.com/Tz4i/sori` flipped
from private to public ahead of the Sparkle work below, since the appcast
feed needed a public, unauthenticated raw-file URL. Flagged before doing it
that the repo's commit history has the user's real email baked into every
existing commit (`git config user.email`, separate from - and not fixed by -
GitHub's own "keep my email private" account setting, which only affects
web-UI-authored commits/profile display, not commit objects already in
history). User chose to switch `git config user.email` to their GitHub
noreply address (`92614574+Tz4i@users.noreply.github.com`) for *future*
commits rather than rewrite existing history.

**Sparkle auto-updates (2026-07-30)** — added end-to-end: SPM dependency,
signing, feed hosting, in-app UI, and documentation, following a pattern the
user had already shipped once before on another app (Grab).
- Sparkle 2.9.4 (latest stable, tarball checksum-verified against GitHub's
  published digest) added via SPM in `project.yml`, pinned in the
  now-tracked `Package.resolved`.
- A **new** EdDSA key pair generated specifically for Sori
  (`generate_keys --account com.sebastianzapata.sori`) - confirmed live via
  `generate_keys -p` that this machine's keychain already held a *different*
  app's (Grab's) key under the default account, and confirmed both keys
  coexist independently afterward. Public key committed to `Info.plist`
  (`SUPublicEDKey`); private key never left the keychain.
- `SoriUpdaterController.swift` wraps `SPUStandardUpdaterController`,
  constructed at app-launch scope like every other controller so background
  checks start immediately. "Check for Updates…" added to the gear settings
  menu. `Info.plist` configures daily automatic checks
  (`SUScheduledCheckInterval=86400`) and prompt-before-install
  (`SUAutomaticallyUpdate=false`) - never silent.
- Feed: `appcast.xml` committed at the repo root, served via its
  `raw.githubusercontent.com` URL (`SUFeedURL`); update payloads attached to
  GitHub Releases. Confirmed the raw URL resolves (200) after pushing.
- `RELEASING.md` written as the operational runbook (version bump → build →
  `ditto` zip → `sign_update` → GitHub Release → appcast entry → push),
  including a dedicated, prominent warning that builds are **not notarized**
  (Apple Development signing, not Developer ID) - Gatekeeper will block both
  first install and every future update on any Mac other than the build
  machine, with the right-click-Open workaround documented for end users and
  Developer ID + notarization noted as the real fix if that's ever wanted.
- Full sign path dry-run tested end-to-end before any real release (a
  throwaway zip of the then-current build, `sign_update` then
  `sign_update --verify` exit 0) before deleting the test artifact.

**Version 1.1 cut and shipped (2026-07-30)** — the first real release since
Sparkle was wired in, and the first version capable of receiving Sparkle
updates itself (nothing to update *from*, since 1.0 predates Sparkle
entirely). `CFBundleShortVersionString` 1.0→1.1, `CFBundleVersion` 1→2.
Built Release config, `ditto`-zipped, signed with Sori's key
(`sign_update --verify` confirmed valid), attached to GitHub Release
[v1.1](https://github.com/Tz4i/sori/releases/tag/v1.1) (download URL
confirmed live, 200), and the corresponding `<item>` added to `appcast.xml`
and pushed. Release notes cover Launch at Login, the crash fix, the
permission-banner UX fixes, and Sparkle itself. Noted for next time: pushing
an appcast change doesn't take effect on the public `raw.githubusercontent.com`
URL for up to 5 minutes (`cache-control: max-age=300`) - verify what was
actually pushed via `git show HEAD:appcast.xml` rather than assuming a
CDN response is current.

## Known gaps / not yet verified

- **Launch-at-Login registration itself is unverified.** `LaunchAtLoginController`
  is implemented and the app builds/runs, but nobody has yet: toggled it on
  and confirmed "sori" appears in System Settings > General > Login Items &
  Extensions; toggled it off and confirmed it disappears; or exercised the
  `.requiresApproval` path (register succeeds but macOS gates on user
  approval - the hint + "Open Login Items Settings…" button are implemented
  but untested). `sfltool dumpbtm` was checked once before any toggling and
  showed no `sori` entry, confirming the default-OFF requirement only - not
  the register/unregister path itself.
- **The gear-icon settings menu's final layout (no chevron, nudged right)
  has not been visually re-confirmed live.** The user saw and liked the
  gear-on-the-Quit-row placement via screenshot, then asked for the arrow
  removed and the icon nudged - that change was built and the app relaunched,
  but no screenshot/confirmation came back afterward before the session
  ended.
- **`NSWindow.didBecomeKeyNotification` as a proxy for "the popover just
  reopened"** (used to call `LaunchAtLoginController.refreshStatus()`) is
  implemented and reasoned through (see CLAUDE.md's new "Login item &
  popover-chrome notes" section) but not independently confirmed to actually
  fire on every popover open on this macOS build.
- Driving this app's UI directly (clicking the menu bar icon, the gear, the
  toggle) isn't something Claude can do in this environment - `osascript`/
  System Events lacks Accessibility permission here (`-1719` error), so
  verification of new UI depends on the user's own clicks + screenshots
  rather than automated interaction. Worth granting Accessibility access to
  whichever terminal app hosts these sessions if more automated UI
  verification is wanted going forward.
- **User-confirmed live (2026-07-26), all four items from the previous
  session's HIG-native UI polish pass:**
  - Popover dynamic-resize-while-open (the CLAUDE.md trap #12 re-test) -
    looks fine with a new app appearing while the dropdown is open; kept the
    grow/shrink-up-to-`maxVisibleApps` approach rather than reverting to a
    fixed size. Not a from-scratch stress test, but good enough to move on -
    revisit if a future report looks like "second app replaces the first"
    again.
  - ⌘Q on the Quit row - works.
  - Rest of the polish pass (material background, typography, dimmed-state
    treatments, boost tint, menu bar icon) - looks good.
  - System OUTPUT/INPUT device pickers (`SystemDeviceMenu`) - work, switch
    the system-wide default device as expected.
- **250ms poll's CPU cost (~4.4% avg, up from ~1.3% at 1s) is an open
  question, not a settled tradeoff.** Acceptable for now, but a candidate
  future optimization is adaptive polling — e.g. poll fast (250ms) only
  while the menu is open or something is actively producing audio, and back
  off toward the old 1s (or slower) the rest of the time, rather than
  paying the fast-poll cost at all times regardless of whether anyone's
  looking or listening.
- **Multi-PID grouping under real simultaneous load is unverified by ear.**
  Confirmed structurally (the resolution/grouping code path is exercised and
  correct) and confirmed at the data layer for single-PID-per-app cases live,
  but never actually watched/listened to one slider move attenuate 2+
  simultaneous PIDs of the *same* app together in real time.
- **200% per-app boost limiter engagement is unverified by ear.** The
  limiter's log line (`Limiter ENGAGED/not engaged`) was implemented and
  reasoned through but never confirmed against a real quiet source pushed to
  200% while someone listened for both "audibly louder" and "no harsh
  clipping." (The System section's OUTPUT row briefly had its own boost
  reusing this same path; it was removed again before ever being verified
  either way, see Done above - this gap is now specifically about the
  per-app case only.)
- WebKit name-suffix matching (`" Graphics and Media"`, `" Web Content"`,
  `" Networking"`) is a heuristic tied to macOS's current naming convention
  for these XPC service instances — only the GPU/"Graphics and Media" suffix
  has been confirmed live; the other two are included defensively but untested.
- `everActiveBundleIdentifiers` / persisted-pinned apps only ever grow within
  a session (and across relaunches for persisted non-default settings) —
  there's no "forget this app" affordance yet if the list gets long.
- The per-app tap engine (as opposed to the System section's OUTPUT/INPUT
  rows, which do handle this) still doesn't react to the user switching the
  *system default* output device mid-session for apps at "No Redirect" —
  only an explicit redirect target's own disconnect/reconnect is handled.
- **"Check for Updates…" has never actually been clicked.** The menu item,
  `SoriUpdaterController`, and the full sign/appcast/release pipeline are
  built and a real 1.1 release exists in the feed, but nobody has clicked
  the button and watched Sparkle's own UI find and offer it - same
  Accessibility-permission limitation as every other UI click-through gap
  above.
- **Builds are not notarized.** Every install and every future update will
  trip Gatekeeper on any Mac other than the build machine - by design for
  now (documented in `RELEASING.md`), not an oversight, but worth revisiting
  if wider distribution is ever wanted (Developer ID cert + `notarytool`).

## Next

Pick up next session with the Launch-at-Login ground-truth check first (top
item under Known gaps) - toggle it on/off against the real System Settings
Login Items list, since that's the actual feature that session set out to
build and it still hasn't been confirmed working. While in the app, also
click "Check for Updates…" and confirm Sparkle actually finds and offers
1.1 (it won't, from a fresh 1.1 install with nothing newer in the feed - use
a 1.0 build if one's still around, or bump a throwaway 1.2 in the feed
temporarily to test the flow, then revert). Get a fresh screenshot of the
gear icon's final no-arrow/nudged-right state while at it. After that: the
older carried-over list is unchanged - CPU-cost-vs-adaptive-polling,
multi-PID grouping under real simultaneous load, and the 200% per-app boost
limiter (all still unverified by ear/under load, see Known gaps).
