# Progress

Last updated: 2026-07-23

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

## Known gaps / not yet verified

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

## Next

All four items carried over from the HIG-native UI polish pass (popover
resize, ⌘Q, rest of the polish pass, System-section device pickers) are now
user-confirmed live - see Known gaps above. Pick up next session with the
remaining open items: CPU-cost-vs-adaptive-polling, multi-PID grouping under
real simultaneous load, and the 200% per-app boost limiter (all still
unverified by ear/under load, see Known gaps).
