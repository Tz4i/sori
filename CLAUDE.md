# 소리 (Sori)

A macOS menu bar app (LSUIElement, no dock icon, no main window) that lists apps
currently producing audio and gives each one an independent volume slider
(0–200%) and mute, implemented via the Core Audio **process tap** API
(`AudioHardwareCreateProcessTap`, macOS 14.2+ private/system SPI surfaced
publicly in `CoreAudio/AudioHardware.h`).

Bundle ID: `com.sebastianzapata.sori`. Deployment target: macOS 14.4.

## Project layout

- `project.yml` — xcodegen spec. **The `.xcodeproj` is generated, not hand-edited.**
  After adding/removing a source file or changing build settings, run
  `xcodegen generate` from `/Users/sebas/sori` before building.
- `sori/SoriApp.swift` — `@main` App struct, MenuBarExtra scene, all SwiftUI views.
- `sori/AudioRecordingPermission.swift` — TCC permission manager (see below).
- `sori/ProcessAudioTapEngine.swift` — the Core Audio tap/aggregate/IOProc engine.
- `sori/AudioProcessMonitor.swift` — polls Core Audio's process list, groups PIDs
  by owning app, resolves Discord/Safari-style edge cases, owns the "pinned in
  list while silent" logic.
- `sori/AppVolumeController.swift` — per-app gain/mute state, UserDefaults
  persistence, lazily owns a `ProcessAudioTapEngine`.
- `sori/SystemAudioController.swift` — the menu's System section: live
  output/input device volume (`SystemDeviceVolumeController`) and the
  AppleScript-backed alert/sound-effects volume (`SystemAlertVolumeController`).
- `sori/CoreAudioTapSupport.swift` — shared `AudioObjectID` property-read/write helpers.
- `sori/TapEngineDiagnosticTest.swift` — temporary env-var-gated diagnostic
  (`SORI_RUN_TAP_TEST=1`), safe to delete once the engine has a real caller
  beyond volume control (kept for now as a quick sanity check).
- `sori/LaunchAtLoginController.swift` — "Launch 소리 at Login" toggle backed
  by `SMAppService.mainApp` (macOS 13+), surfaced in `SoriApp.swift`'s gear
  settings menu.

## Building and running

This machine's Xcode.app lives on an **external volume**, not `/Applications`,
and the global `xcode-select` points at bare Command Line Tools. Scope the
toolchain per-command instead of changing global state:

```bash
export DEVELOPER_DIR=/Volumes/Untitled/Xcode-beta.app/Contents/Developer
xcodebuild -project sori.xcodeproj -scheme sori -configuration Debug \
  -destination 'platform=macOS' -allowProvisioningUpdates build
```

Signing: `DEVELOPMENT_TEAM: PC7Q8XD735` ("Sebastian Zapata (Personal Team)"),
`CODE_SIGN_STYLE: Automatic`. `-allowProvisioningUpdates` lets Xcode
auto-generate the local "Apple Development" cert on first build if needed.

**Watch for multiple simultaneous instances.** Launching via `open`/`open -n`,
launching the raw binary directly, and running via Xcode's own Run button
(which attaches a debugger and can leave a `SIGSTOP`-resistant, hard-to-kill
process) are three different launch paths that don't dedupe against each
other. It's easy to end up editing/rebuilding code while a *stale* instance
from a different launch path is still the one actually on screen — this
caused a real, time-consuming false bug report during development. Before
concluding something is broken, check `ps aux | grep sori.app` and make sure
only the freshly-built instance is running.

**Debug logging: use stderr, not OSLog.** `log stream`/`log show` were
unreliable for this app's own subsystem in this environment (sometimes worked,
often silently returned nothing even moments after events were confirmed to
have happened via other means). All the diagnostic env vars below write
directly to stderr instead, which was reliable every time:

- `SORI_CHECK_TCC=1` — construct `AudioRecordingPermission`, print its status, exit.
- `SORI_REQUEST_TCC=1` — trigger the real TCC consent request.
- `SORI_RUN_TAP_TEST=1` (+ `SORI_RUN_TAP_TEST_EXIT=1`) — run the temporary
  tap-engine RMS diagnostic (see `TapEngineDiagnosticTest.swift`).
- `SORI_DEBUG_PROCESS_MONITOR=1` — dump the resolved app→PID groups and the
  pinning-decision internals (`everActive`/`interacted`/`pinned`/`currentlyLive`
  sets) on every change.

## Hard-won Core Audio traps

These were each verified live, several after burning real time on a wrong
turn. Don't re-litigate them without re-testing first.

1. **No `AVAudioEngine`, anywhere, ever, in this project.** It cannot be
   wired to a tap-backed aggregate device as an input — it silently keeps
   pulling from the system default input instead, so it *looks* like it
   works but never receives the tapped audio. All I/O goes through
   `AudioDeviceCreateIOProcIDWithBlock` directly on the aggregate device.
   `AVAudioFormat` alone (no engine) is fine for describing the tap's stream
   format.

2. **`CATapDescription`'s convenience initializers set `isExclusive` for
   you — never touch it afterward.** `stereoGlobalTapButExcludeProcesses:`
   sets it `false` (tap everything *except* the list); `stereoMixdownOfProcesses:`
   sets it `true` (tap *only* the list, mixed down to one stream). Flipping
   it manually inverts what the process list means. `ProcessAudioTapEngine.TapTarget`
   picks the right initializer per use case — `.allExcluding` for the
   whole-system diagnostic tap (excluding this app's own pid, to avoid
   feedback), `.only` for per-app volume control (target exactly one app's
   current PIDs).

3. **`muteBehavior = .mutedWhenTapped` is required, or audio doubles.**
   Without muting the tapped process's original output at the tap point,
   the original keeps playing to hardware *and* the gain-adjusted copy also
   plays through the aggregate — every sample doubles. Plain `.muted` mutes
   permanently regardless of tap state (wrong); `.unmuted` doubles (wrong).

4. **Aggregate device must be private, with the real default output device
   as `kAudioAggregateDeviceMainSubDeviceKey`, and `kAudioAggregateDeviceTapAutoStartKey = true`.**
   The tap-list entry's `kAudioSubTapUIDKey` must be the UUID string you set
   yourself on `CATapDescription.uuid` — **not** a value read back via
   `kAudioTapPropertyUID`, which doesn't reliably match what
   `AudioHardwareCreateAggregateDevice` expects and produces a silent,
   tap-less aggregate.

5. **Teardown must happen in this exact order**, or the next tap
   intermittently succeeds but delivers zero-filled buffers:
   `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
   `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
   See `ProcessAudioTapEngine.teardown()`.

6. **`AudioHardwareCreateAggregateDevice` returning `kAudioHardwareIllegalOperationError`
   (1852797029, FourCC `'nope'`)** means a conflicting aggregate already
   exists (usually a previous instance wasn't torn down cleanly) — tear down
   and recreate once (`createAggregateDevice` handles this).

7. **Boost (gain > 1.0) needs a soft-clip limiter**, or Float32 samples
   exceeding ±1.0 hard-clip and distort. `ProcessAudioTapEngine.softClip`
   is a tanh soft-knee starting at 0.9 amplitude — transparent below that,
   asymptotically approaching ±1.0 above it. Only applied when gain > 1.0;
   never touches unity/attenuated playback. Logs "Limiter ENGAGED/not
   engaged" roughly once per second while boosted.

8. **Resolving "which app owns this audio-producing process" needs a
   4-layer fallback chain** (`AudioProcessMonitor.refresh()`), because no
   single API covers every real-world case:
   1. `NSRunningApplication(processIdentifier:).bundleURL` — works for
      ordinary, LaunchServices-registered apps.
   2. **WebKit name-suffix match** — Safari/every WebKit-embedding app's
      audio renders through a truly shared, **launchd-spawned singleton**
      XPC service (`com.apple.WebKit.GPU`, confirmed live: parent pid is
      `1`, i.e. launchd — no process-tree link back to the host app at
      all, and its bundle lives under `WebKit.framework`, not nested in
      any host app either, so neither bundle-path climbing nor
      parent-chain walking can resolve it). The only signal that actually
      encodes ownership is the name macOS itself assigns the instance:
      `NSRunningApplication.localizedName` is literally `"Safari Graphics
      and Media"`. Strip the known suffix (`" Graphics and Media"`,
      `" Web Content"`, `" Networking"`) and match the remainder against
      `NSWorkspace.runningApplications` by name, cross-validated so a
      coincidental name can't mislabel it.
   3. **Parent-process-chain walk** (`sysctl(KERN_PROC_PID)` →
      `kinfo_proc.kp_eproc.e_ppid`) — fallback for shared helpers that
      *are* parented directly to their requesting app (unlike WebKit.GPU).
   4. **`proc_pidpath()` + bundle-path climb** — Discord's actual
      audio-rendering helper (`Discord PTB Helper.app`, launched with
      `--type=utility`) is spawned via raw `posix_spawn` and never
      registers with LaunchServices at all (confirmed live:
      `NSRunningApplication(processIdentifier:)` returns `nil` for it).
      But it's still genuinely nested inside the app's own bundle on disk,
      so resolving the raw executable path and climbing still finds it.

9. **Climb to the *outermost* `.app` ancestor, not the first one found**
   (`URL.topLevelAppBundleURL()`). A helper several `.app`-inside-`.app`
   levels deep (`Discord PTB.app/Contents/Frameworks/Discord PTB
   Helper.app/...`) needs the climb to keep going past the first match.

10. **Also collapsing by top-level bundle only works because it's cross-checked
    against `NSWorkspace.runningApplications`.** Without that check, a
    legitimate background daemon that happens to be packaged as an `.app`
    (confirmed live: Rogue Amoeba's Audio Routing Kit driver agent,
    `arkaudiod`, living at `.../ARK.driver/Contents/Resources/Audio Routing
    Kit (ARK).app/...`) climbs to a real `.app` bundle too, but was never
    actually *launched* as an application — so it must not be mistaken for
    one. Same check also prevents the opposite mistake (see #8.2): merging
    unrelated apps that happen to share a generic system helper bundle id.

11. **`MenuBarExtra(.menu)` cannot host a draggable `Slider`.** It renders
    content as a real `NSMenu`; `NSMenuItem`-hosted views don't support
    drag interaction (confirmed live — the slider rendered but couldn't be
    dragged). Use `.menuBarExtraStyle(.window)` instead, which backs the
    dropdown with a real `NSHostingView`/window and supports full SwiftUI
    interactivity.

12. **`MenuBarExtra(.window)` doesn't reliably resize when content grows
    from a background update.** It sizes the hosting window once and
    doesn't consistently re-measure it when the SwiftUI content's ideal
    size changes later from something other than direct user interaction
    (confirmed live — looked exactly like "a second app replaces the
    first" when a new row appeared while the dropdown was already open).
    Original fix: give the popover a **fixed size** (`280×360`) and wrap
    the variable-length app list in a `ScrollView` — the window's own size
    never needs to change, only the scrollable content inside it does.
    **Re-tested on the current macOS build (HIG-native UI polish pass) and
    no longer reproduces.** The popover was changed to grow/shrink with the
    Applications list up to `maxVisibleApps` rows (only scrolling past that
    cap) instead of staying a hard-coded fixed height. User-confirmed live
    (2026-07-26): the resize-while-open scenario (new app starts producing
    audio while the dropdown is already open) looks fine now, not a
    from-scratch stress test — good enough to keep this approach rather than
    reverting to the fixed-size popover. Revisit if a future report looks
    like "second app replaces the first" again.

13. **The tap engine is lazy by construction, and must stay that way.**
    `AppVolumeController` only creates a `ProcessAudioTapEngine` when
    `effectiveGain != 1.0`; `updatePIDs([])` (empty PID set — app went
    silent) tears the tap down without creating one. Never hold a tap open
    on a silent app "just in case."

14. **List membership ("should this app have a row") is deliberately
    broader than "is a tap active."** A row appears if the app is
    currently active, OR was ever seen active this session, OR the user
    ever touched its slider/mute this session, OR it has a persisted
    non-default gain/mute from a previous launch — this last one is what
    lets you pre-set a volume before an app has ever made a sound. The
    "ever active" / "ever touched" tracking is intentionally **session-only,
    in-memory, never persisted** (`AudioProcessMonitor.everActiveBundleIdentifiers`,
    `AppVolumeController.hasBeenInteractedWith`) — only the numeric
    gain/mute values persist to UserDefaults, not list membership itself.
    **Pin permanently once true, never on a timer.** A time-limited grace
    period was tried first (5s after last interaction) to stop a slider
    drag through the exact 100% snap point from yanking the row away
    mid-drag — but it just moved the bug: the row would vanish ~5 seconds
    after being set to exactly 100%, since that's often the last thing a
    user does before the window quietly expires. `hasBeenInteractedWith`
    is a one-way permanent flag, not a decaying timestamp.

15. **TCC audio-capture permission** uses the same private SPI dance as
    insidegui/AudioCap: `dlopen` `/System/Library/PrivateFrameworks/TCC.framework`,
    `dlsym` `TCCAccessPreflight`/`TCCAccessRequest` for
    `kTCCServiceAudioCapture`. This is why `NSAudioCaptureUsageDescription`
    is in Info.plist and why the app must be signed with a real
    Development Team (ad-hoc/unsigned builds get inconsistent TCC behavior).

16. **Not every output device is `kAudioDevicePropertyVolumeScalar`'s master
    element (element 0).** Confirmed live on this project's own dev
    hardware: neither the default output device (AirPods, as main output)
    nor the default *system* output device (a wired headset) expose a
    master volume control at all — only per-channel (element 1, 2, ...). A
    different default *input* device (also AirPods) does expose a real
    master element. Any code reading/writing this property needs the
    master-or-per-channel-average fallback (`HardwareVolumeAddressing` in
    `SystemAudioController.swift`) — don't assume master exists just because
    it did on whichever device you tested first.

17. **`kAudioHardwarePropertyDefaultOutputDevice` and
    `kAudioHardwarePropertyDefaultSystemOutputDevice` are not the same
    device** on this dev machine (confirmed live: main output is AirPods,
    system/alert output is a Razer headset) — they can diverge on any
    machine with a "play sound effects through" device set differently
    from the main output, or with third-party audio routing tools
    installed. `ProcessAudioTapEngine.createAggregateDevice` has always
    targeted `DefaultSystemOutputDevice` for every per-app tap's aggregate;
    this is pre-existing behavior, not something introduced by the System
    section. Anything new that reuses that aggregate-creation path (e.g. a
    future system-wide output boost tap) needs to reckon with which of the
    two devices it actually wants to render to before assuming they match.

18. **macOS's alert/UI sound volume ("Sound Effects" → "Alert volume") is
    not a Core Audio HAL property at all**, and isn't the older documented
    `com.apple.sound.beep.volume` CFPreferences key either — confirmed live
    by diffing every single `defaults` domain on the machine (`defaults
    domains`, ~40 of them) before and after changing it via `osascript -e
    'set volume alert volume N'` (zero domains changed), and by reading
    `kAudioDevicePropertyVolumeScalar` directly on the actual default
    *system* output device and finding it holds a completely different,
    independently-moving value. It's private, non-persisted,
    coreaudiod-internal state with no discoverable `AudioObjectID`
    selector — grepped the CoreAudio/AudioToolbox/AudioHardwareService SDK
    headers and exported symbols, nothing. The only stable, working,
    Apple-supported surface is the Standard Additions `set volume alert
    volume` / `get volume settings` AppleScript command pair (what System
    Settings' Sound pane and `osascript` itself use) — drive it via
    in-process `NSAppleScript`, not by shelling out per interaction. There's
    no listener for it either; `SystemAlertVolumeController` polls.

19. **A private aggregate device (`kAudioAggregateDeviceIsPrivateKey = true`)
    is invisible to *other* processes enumerating
    `kAudioHardwarePropertyDevices`, but IS visible to its own creating
    process's enumeration of that same property.** Confirmed live, and the
    hard way: an earlier check of this (spinning up a tap in a *separate*
    throwaway process and grepping the device list for it) found nothing and
    was taken as proof private aggregates never appear in the list at all -
    that conclusion was wrong, just under-scoped. Checked from *inside* the
    owning process, the aggregate shows right up. This caused a real,
    confirmed-live bug: `AvailableAudioDevices` (which lives inside Sori
    itself) saw its own freshly-created, randomly-UUID-named per-tap
    aggregate as a "new device" every time any tap anywhere in the app
    rebuilt - which (combined with `refreshTapForRedirectChange` rebuilding
    unconditionally on any device-list change, see `AppVolumeController`)
    produced a self-sustaining rebuild loop: rebuild → new aggregate UUID →
    device list "changes" → every redirect target re-resolves → rebuild →
    ... forever, once a second, tied to `AudioProcessMonitor`'s poll
    interval. Audibly, this sounded like a redirected app's audio cycling
    between the redirect target and the system default every second (the
    ~30-40ms teardown gap on each cycle briefly un-mutes the original
    process's direct output before the replacement tap re-mutes it).
    **Fix**: `SoriOwnedAggregateDevices` tracks the UID of every aggregate
    `ProcessAudioTapEngine` creates (registered on create, unregistered on
    teardown), and `AvailableAudioDevices.refresh()` filters its own
    enumeration against it - by tracked UID, not by name-string matching,
    so a coincidentally-similar-named real device can't be wrongly filtered
    and a naming change can't let Sori's own devices slip through. As
    defense in depth against this class of bug recurring,
    `AppVolumeController` also now compares the *specific* redirect target
    value before rebuilding (`appliedRedirectDeviceID` vs
    `effectiveRedirectDeviceID` - no-op unless it actually changed) and
    trips a loud, logged rebuild-loop guard if a single app's tap rebuilds
    more than 5 times in 10 seconds regardless of cause, suppressing further
    automatic rebuilds rather than letting a future regression manifest as
    cycling audio again.

20. **`kAudioProcessPropertyIsRunningOutput` does not reliably fire property-
    change notifications - confirmed live, zero fires across every test
    tried.** `AudioProcessMonitor` detects "an app started/stopped producing
    audio" by polling `kAudioHardwarePropertyProcessObjectList` +
    `kAudioProcessPropertyIsRunningOutput` on a timer (every 250ms) rather
    than via listeners, and that's a deliberate choice, not an oversight:
    - `kAudioHardwarePropertyProcessObjectList` **does** fire reliably - an
      `AudioObjectAddPropertyListenerBlock` on the system object for this
      selector fired within ~2ms of both `afplay`'s process object being
      created and (2.9s later, when playback finished) destroyed. This part
      of the API works exactly as you'd hope.
    - `kAudioProcessPropertyIsRunningOutput`, registered per-process-object,
      **never fired once**, across three separate live tests: (1) 3 minutes
      of real interaction (playing/pausing audio in already-running apps
      with existing process objects - Safari, Music), (2) a fully-controlled
      `afplay` run where the watched process object's `IsRunningOutput`
      value necessarily flipped true-then-false within a precisely-timed
      ~2.9s window, and (3) `osascript -e 'beep 3'` on an existing,
      long-lived process object (`systemsoundserverd`). Reading the property
      directly always returns the correct live value - it's specifically
      the *change notification* that doesn't arrive.
    - Net effect: `kAudioHardwarePropertyProcessObjectList` alone can only
      tell you a *new* process object appeared/disappeared, which happens
      far less often than "an already-known process started making sound
      again" (the common case - Safari's WebKit.GPU process, Music's
      process, etc. persist across many separate playback sessions). It
      can't substitute for polling `IsRunningOutput`, so a hybrid
      (listener for new processes + poll for output state) wasn't worth the
      added complexity over just polling faster. 250ms was chosen as a
      straightforward reduction of the "audio plays briefly on the wrong
      device before the tap engages" window (confirmed live down from the
      polling interval to effectively the same ~15-40ms tap-setup time,
      instead of up to ~1s) - measured live at ~4.4% average CPU for the
      whole app, up from ~1.3% at a 1s interval. Re-test this finding rather
      than assuming it if a future macOS release is the trigger for
      revisiting it - undocumented behavior like this is exactly the kind
      that changes across OS versions without notice.

## Login item & popover-chrome notes (not Core Audio, kept separate from the
numbered list above on purpose - these are SwiftUI/AppKit/ServiceManagement
findings, not Core Audio ones)

- **`SMAppService.mainApp` is the whole story for "launch at login" - no
  helper-app target needed.** Unlike the deprecated `SMLoginItemSetEnabled`
  (which required a separate helper `.app` embedded in the bundle),
  `SMAppService.mainApp.register()`/`.unregister()` register the main app
  bundle directly. `LaunchAtLoginController` wraps this as a thin,
  re-readable reflection of `SMAppService.mainApp.status` (`.enabled`,
  `.requiresApproval`, `.notRegistered`, `.notFound`), same philosophy as
  `SystemDeviceVolumeController` toward hardware volume - the system, not
  Sori, is the source of truth, and `.requiresApproval` still reads as "on"
  for the toggle since registration itself succeeded.
- **`SMAppService.openSystemSettingsLoginItems()` is the correct way to send
  the user to the Login Items & Extensions pane** for the `.requiresApproval`
  case, not a hand-built `x-apple.systempreferences:` URL scheme - it's the
  officially supported static method added alongside `SMAppService` itself,
  so it won't silently break across a future System Settings redesign the
  way a guessed URL scheme could.
- **A `Toggle` inside a SwiftUI `Menu` renders as a real checkable
  `NSMenuItem`** (checkmark-style, same as a normal macOS app's "Launch at
  Login" menu command) - this is how the gear-icon settings menu
  (`SettingsMenu` in `SoriApp.swift`) hosts the login-item toggle natively,
  without needing a separate checkbox control or custom menu-item view.
- **`.menuIndicator(.hidden)` (SwiftUI, macOS 14+) removes the small
  disclosure chevron a `Menu` styled with `.menuStyle(.borderlessButton)`
  draws next to an icon-only label.** Used on the footer gear icon so it
  reads as a plain icon button, not an icon-plus-caret control; the
  per-app/System-section device-picker menus (`RedirectDeviceMenu`,
  `SystemDeviceMenu`) still show their chevron deliberately, since those
  *are* pickers where the caret is the correct affordance.
- **`MenuBarExtra(.window)`'s content view persists across opens rather than
  being torn down and rebuilt** (this is *why* trap #12 above was ever a
  problem in the first place) - so a plain SwiftUI `.onAppear` won't refire
  every time the user reopens the popover. Since this app has no other
  window (`LSUIElement`, no main window), listening for
  `NSWindow.didBecomeKeyNotification` via
  `NotificationCenter.default.publisher(for:)` is a reliable stand-in for
  "the popover just opened," used to re-read `SMAppService`'s live status in
  case the user changed it from System Settings directly while the popover
  was closed. **Not yet independently verified live** that this notification
  actually fires on every popover open on this macOS build - implemented and
  reasoned through, same unverified status as the rest of this feature (see
  PROGRESS.md).

## Style notes

- Comments explain *why*, especially "documented trap" reasoning discovered
  through live testing — not what the code obviously does.
- No AVAudioEngine (see above) — this is load-bearing, not a style
  preference; a future contributor reaching for it to "simplify" the tap
  engine will silently break audio capture.
- Prefer fixing the actual property/API resolution edge case over adding
  UI-layer workarounds — several bugs in this project turned out to be data
  resolution issues (Discord, Safari) that only *looked* like UI bugs.
