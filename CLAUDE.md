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
- `sori/LaunchAtLoginController.swift` — "Launch 소리 at Login" toggle backed
  by `SMAppService.mainApp` (macOS 13+), surfaced in `SoriApp.swift`'s gear
  settings menu.
- `sori/SoriUpdaterController.swift` — thin wrapper around Sparkle's
  `SPUStandardUpdaterController`, surfaced as "Check for Updates…" in the
  gear settings menu. See "Distribution (Sparkle auto-updates)" below and
  `RELEASING.md` for the actual release-cutting process.
- `sori/SoriDebugLog.swift` — timestamped lifecycle logging (tap/aggregate
  create-destroy, IOProc start/stop, device-list changes, rebuild triggers),
  **always writes to a persistent file** (`~/Library/Logs/Sori/sori.log`,
  rotated at 5MB), not just stderr — see trap-list addendum below for why.

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
directly to stderr instead, which was reliable every time.

**Possible confound found later, not yet reconciled with the above:** in a
later session, plain `log stream --predicate '...'` from an interactive shell
silently did nothing (`(eval):log:1: too many arguments`) - because `log` is
a **zsh shell builtin** on this machine (`type log` → "shell builtin"), which
intercepts the bare `log` command instead of running the actual CLI tool.
Explicitly invoking `/usr/bin/log stream ...` worked cleanly and reliably
every time it was tried after that (confirmed live, captured real-time
`Logger.notice` output from a running tap engine). Whether this shadowing
explains every prior "OSLog is unreliable here" observation above is
unconfirmed - those were from a different context (this app's own launched
process, not necessarily this exact interactive-shell invocation path) - but
it's a strong enough confound that a future session doubting OSLog again
should try `/usr/bin/log` explicitly before concluding it's the tool that's
unreliable rather than the shell.

- `SORI_CHECK_TCC=1` — construct `AudioRecordingPermission`, print its status, exit.
- `SORI_REQUEST_TCC=1` — trigger the real TCC consent request.
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
      that changes across OS versions without notice. **The ~4.4% figure is
      now superseded** - it was measured before trap #21's per-tick caching
      fix; idle CPU at this same 250ms interval is ~1.85% now (see trap #21
      and PROGRESS.md). The interval itself and the polling-vs-event-driven
      reasoning above are unaffected - #21 fixed per-tick cost, not
      frequency.

21. **`AudioProcessMonitor`'s per-pid app-resolution cache
    (`cachedRunningApps...`, `groupKeyCache`, `unresolvablePIDs`) must NOT be
    rebuilt on every poll tick, or the CPU win here reverts.** Profiled live:
    re-snapshotting `NSWorkspace.shared.runningApplications` and rebuilding
    `runningAppsByPID`/`runningAppsByName` from it every 250ms tick was
    ~16-24ms of a ~31-39ms tick - by far the dominant per-tick cost, an order
    of magnitude past everything else in `refresh()` combined (confirmed via
    a controlled A/B under an identical frozen app set: caching the pid
    resolution chain alone, without also fixing this, made no measurable
    difference - 5.38% either way). Fixed by caching the snapshot and its two
    lookup dictionaries as instance state, invalidated ONLY by
    `NSWorkspace.didLaunchApplicationNotification`/
    `didTerminateApplicationNotification` (the only two notifications that
    can actually change a pid's owning app - hide/unhide, activate/deactivate,
    etc. don't and aren't observed) via a dirty flag, consumed lazily at the
    top of the next `refresh()` tick rather than rebuilt synchronously inside
    the notification handler - so a burst of several launches/terminations
    between two polls still costs exactly one rebuild, not one per
    notification. Three things about this design a future "simplify this"
    pass needs to preserve:
    - **Negative caching (`unresolvablePIDs`)** - a pid that never resolves
      to a genuine app (a background daemon that happens to keep producing
      audio) must not retry the resolution chain, or trigger the fallback
      rebuild below, every single tick for as long as it keeps running - it's
      cached as unresolvable and skipped outright, evicted only when the pid
      itself disappears (same eviction timing as the positive
      `groupKeyCache`).
    - **The launch-notification-vs-poll-tick race** - a pid can start
      producing audio (visible to Core Audio) before `NSWorkspace`'s launch
      notification has been delivered/processed, or before this tick's lazy
      dirty-flag consumption has run. If resolution fails against the
      current cache, `refresh()` forces exactly one full re-snapshot as a
      fallback and retries - bounded to at most once per tick
      (`didFallbackRefreshThisTick`) regardless of how many pids fail in that
      tick, specifically so this fallback path can't itself regress into
      "re-snapshot every tick."
    - **This did not break "an already-known app starts playing" detection**,
      which is the entire reason for polling at 250ms in the first place -
      that detection is completely independent of this cache
      (`kAudioProcessPropertyIsRunningOutput` is still read fresh every tick
      for every live pid, per trap #20 above). Confirmed live via a real
      `afplay` test: 229ms from process launch to `updatePIDs` picking it up,
      25ms from playback ending to the pid being dropped - both within one
      poll tick, unchanged from before this cache existed.

    Net effect, measured under an identical frozen app set before/after:
    idle CPU dropped from 5.38% to 1.85% at the same 250ms poll interval -
    the fix was per-tick cost, not polling frequency. An "adaptive polling"
    idea (poll fast only while something's active, back off otherwise) was
    on the table in PROGRESS.md's Known Gaps before this fix; it would have
    been the wrong lever entirely and is now removed from there.

22. **`ProcessAudioTapEngine.process()` (the realtime IOProc callback) must
    never allocate, lock, take a weak reference, or log - a future addition
    to this function needs to keep it that way.** Three violations were
    found and fixed in the same session:
    - **`rmsHandler`, a mutable closure property read every callback, was
      removed entirely** rather than fixed - `_gain`/`limiterEngaged` are
      plain `Float`/`Bool`, where a torn read is harmless (at worst a
      one-callback-stale value), but a closure is a refcounted reference -
      a torn read of one is a real use-after-free/corruption risk, not just
      a stale value. Its only caller was `TapEngineDiagnosticTest.swift`
      (a temporary, env-var-gated, `SORI_RUN_TAP_TEST=1` diagnostic that
      predated the engine having a real caller), deleted in the same
      session now that per-app volume control is the real, permanent
      caller and the diagnostic had no remaining purpose.
    - **`logger.notice(...)` was called directly from `process()`**,
      throttled to ~1-in-100 callbacks to approximate "once a second."
      `os_log` can allocate and take locks - throttling lowers the
      *probability* of a glitch, it doesn't make the call realtime-safe.
      Fixed by removing all logging from `process()` and adding a
      `Timer(timeInterval: 1.0, ...)` scheduled on `RunLoop.main` (`.common`
      mode) inside `ProcessAudioTapEngine` itself, started in `start()` and
      invalidated in `teardown()`, which reads `limiterEngaged`/`gain` and
      logs from the main thread instead. Confirmed live: boosted a real
      per-app tap to gain 1.8 (`afplay` piped through Terminal's
      parent-chain-resolved pid) and streamed `/usr/bin/log stream`
      (see the debug-logging note above for why `/usr/bin/log`, not bare
      `log`) filtered to this subsystem/category - "Limiter not engaged at
      gain 1.800000" appeared at a clean, consistent ~1s cadence, always
      from the exact same `PID:TID`, confirming both that it fires
      reliably and that it's coming from one fixed (main) thread, not the
      per-callback IO thread.
    - **The IOProc block captured `[weak self]`, and called `self?.process(...)`
      every callback.** Every weak load takes the Swift runtime's global
      side-table lock - forbidden here regardless of how cheap it seems.
      The natural-looking fix, `[unowned(unsafe) self]`, was considered and
      **rejected**: it would depend on `AudioDeviceStop` (called first in
      `teardown()`) having fully drained the IO thread before `self` can be
      freed, and while that dependency is *probably* fine in practice (this
      project's teardown ordering already depends on `AudioDeviceStop`
      being synchronous - see trap #5), a web search surfaced an Apple DTS
      engineer's own caveat on the closely-related AudioUnit render
      callback: it "can continue to execute for a short period" after the
      stop call returns. That's exactly the race `unowned(unsafe)` cannot
      tolerate, and the risk (a realtime-thread use-after-free, this
      whole batch of fixes' entire reason for existing) was judged not
      worth taking just to avoid one extra allocation. Fixed instead by
      hoisting the two fields the callback actually touches (`gain`,
      `limiterEngaged`) into a private nested `TapIOState` class that the
      IOProc block captures **strongly** and the engine ALSO holds a
      strong reference to for its own whole lifetime - so `ioState` can't
      be deallocated while either the engine or the still-registered block
      exists, regardless of exactly when the last callback fires relative
      to teardown, sidestepping the timing question entirely rather than
      betting on it. `process()` became a `private static func` taking
      `state: TapIOState` explicitly, so the closure has no implicit
      capture of `self` hiding in it either. `gain`/`limiterEngaged` on the
      engine are now computed properties that forward to `ioState` - same
      external API, no functional change for any caller.

23. **A crashed/killed process's PRIVATE aggregate device does not appear to
    leak past its death on this machine's current macOS build - confirmed
    live, and this contradicts what an earlier session believed based on
    real field crash history.** `OrphanedAggregateSweeper.sweepAtLaunch()`
    exists to enumerate and destroy any `Sori-Tap-`-named aggregate left
    behind by a previous crashed launch, on the theory (stated as an
    observed fact from real crashes) that "every crash leaves an orphaned
    aggregate device that nothing ever reaps." Tested four ways before
    trusting that theory at face value:
    1. A separate throwaway process created a private `Sori-Tap-`-prefixed
       aggregate and exited WITHOUT destroying it (simulating a leak) - a
       fresh real Sori launch's sweep found and destroyed **0** orphans.
    2. A third, completely separate enumeration process couldn't see that
       same aggregate via `kAudioHardwarePropertyDevices` even while its
       creator was still alive - consistent with trap #19 (private
       aggregates are only visible to their own creating process), but this
       extends it further: visibility doesn't transfer to a LATER launch of
       the same app either, only to the literal same process.
    3. Reusing the exact same UID as the abandoned aggregate from (1)
       succeeded cleanly with no `kAudioHardwareIllegalOperationError` -
       no evidence of a lingering internal conflict either.
    4. The closest-to-real-crash test: created an aggregate, actually
       started IO on it (`AudioDeviceCreateIOProcIDWithBlock` +
       `AudioDeviceStart`, matching what a real tap does), then `kill -9`'d
       the process while it was actively running - still **0** orphans found
       by a subsequent real Sori launch's sweep, and still invisible to a
       third-party enumeration process afterward.

    Net conclusion from this machine's current OS build: coreaudiod appears
    to clean up a private aggregate device's registration when its creating
    process's connection dies, crash or not - so the sweep, as built,
    correctly reports 0 in every test thrown at it here, and there was
    nothing to demonstrate it destroying for real. **The code is being kept
    anyway** - defense-in-depth against a different macOS version or
    condition genuinely leaking (untested: crashing mid-`AudioHardwareCreateAggregateDevice`
    itself, a real machine reboot instead of a plain process kill, older
    deployment-target OS versions actually installed on end-user Macs vs.
    this dev machine's beta SDK), and the swept-count log line is itself a
    free, cheap diagnostic - if it's ever nonzero in real use, that's a
    concrete, actionable signal, not a launch-time verification exercise.

    **Follow-up: the process tap object was the next suspect, and it tests
    the exact same way.** `AudioHardwareCreateProcessTap`/
    `AudioHardwareDestroyProcessTap` is a genuinely separate Core Audio
    object from the aggregate device (enumerable on its own via
    `kAudioHardwarePropertyTapList`, `'tps#'` - undocumented in this file
    until now), and `CATapDescription.isPrivate` is the exact same
    "only visible to the client process that created it" contract as the
    aggregate's private flag (Apple's own doc comment on the property, not
    an inference). Repeated the same four-part test against taps instead of
    aggregates: a throwaway process created a private tap and was `kill -9`'d
    while it had a real IOProc actively running on it (closest analog to a
    genuine crash) - a fresh enumeration process saw **0** taps via
    `kAudioHardwarePropertyTapList` both before and after the kill, and
    reusing the exact abandoned tap's UUID in a brand-new
    `AudioHardwareCreateProcessTap` call succeeded cleanly with no
    `kAudioHardwareIllegalOperationError`. Identical result to the
    aggregate case, by the same mechanism (the `isPrivate` contract), not a
    coincidence.

    **So: neither Core Audio object Sori creates appears to leak past
    process death on this OS build - the crash-recovery half of trap #5's
    `createAggregateDevice` retry (tearing down a stale aggregate on
    `kAudioHardwareIllegalOperationError`) has no confirmed mechanism to
    ever fire from a previous process's leftovers.** The retry is not being
    removed - `prepare()` always generates a fresh random UUID per call
    (`aggregateUID = UUID().uuidString`), so it can't self-conflict either
    (a genuine same-instance collision isn't reachable through this
    codebase's own call graph: `start()` no-ops if already running, and
    `rebuild()` always tears down fully before starting again) - but on the
    evidence gathered here, this retry path is effectively unreached dead
    code for BOTH the reason it was written (same-instance conflict - not
    producible) AND the reason it was hoped to also cover (cross-process
    leak recovery - no leak to recover from). If
    `kAudioHardwareIllegalOperationError` conflicts are ever actually seen
    in the field again, neither hypothesis tested here explains it, and the
    cause is something not yet identified - not a leaked aggregate, not a
    leaked tap, and not a same-instance double-create.

24. **Per-app taps don't automatically follow the system default OUTPUT
    device changing mid-session - `AudioProcessMonitor` now listens for
    `kAudioHardwarePropertyDefaultSystemOutputDevice` (trap #17 - NOT
    `kAudioHardwarePropertyDefaultOutputDevice`) and rebuilds the affected
    taps.** `ProcessAudioTapEngine.createAggregateDevice` bakes the output
    device into the aggregate at CREATION time and never re-reads it - so
    switching outputs (e.g. AirPods -> speakers) left every gain-adjusted/
    tapped app rendering to the OLD device forever, an audible split from
    everything untapped (which correctly follows the new default via plain
    Core Audio routing, no Sori involvement). Fixed with a single
    process-wide listener in `AudioProcessMonitor` (not per-`AppVolumeController`
    - avoids N redundant listeners) that, on fire, calls
    `AppVolumeController.refreshTapForSystemDefaultOutputChange()` on every
    controller. That method is a no-op for any app with an explicit redirect
    (`redirectDeviceUID != nil` - staying on the chosen device regardless of
    the system default is the entire point of a redirect) and for any app
    with no live tap (nothing baked in to be stale) - only a tapped,
    non-redirected app's aggregate actually rebuilds. This is deliberately a
    DIFFERENT trigger from `refreshTapForRedirectChange()` (fired by
    `AvailableAudioDevices`' device-LIST changing, i.e. hot-plug): the two
    are mutually exclusive by construction (one only ever acts on redirected
    apps, the other only ever acts on non-redirected apps), so a single
    real-world event that happens to fire both listeners at once (e.g.
    unplugging a device that was simultaneously someone's redirect target
    AND the system default) can't double-rebuild the same controller.
    Reuses `rebuildTap`'s existing rebuild-loop guard - a real default-output
    switch is a one-time event, not a loop, and this path doesn't call
    `resetRebuildLoopGuard()` (that's reserved for explicit user interaction
    on the app in question, per its own doc comment - a system-wide default-
    output change isn't that). **Not yet independently confirmed live** -
    the listener registers without error at launch (confirmed), but
    actually switching the system default output device to watch a tapped
    app's audio follow was left to the user to verify by ear, since doing
    that programmatically here would mean changing the real machine's live
    audio routing out from under whatever the user might be doing at the
    time.

25. **A live slider drag oscillating across the ±4% "snap to 100%" zone
    (`snappingGain` in `SoriApp.swift`) used to tear the tap down and
    rebuild it from scratch on every single crossing - confirmed live via a
    temporary programmatic stress test (built, used, removed) at ~97
    rebuilds / 67 teardowns in under 4 seconds of simulated fast
    back-and-forth, every single one starting cold (`hadRunningTap=false`),
    meaning the tap essentially never survived long enough to pass coherent
    audio.** This was the real cause of a reported "fast bidirectional
    slider popping / audio sometimes stops entirely until the slider moves
    again" regression - initially suspected to be the `TapIOState` realtime
    refactor (trap #22), but a diff against pristine HEAD showed gain
    application was identical (instantaneous per-buffer, no ramping) before
    and after that refactor - it was never introduced OR removed, meaning
    zipper noise alone didn't explain the severity or the directional
    asymmetry. The actual mechanism: `AppVolumeController.applyGain()`
    treated exactly-unity gain as "tear the tap down" (the lazy-tap
    optimization, trap #13) - so a drag crossing 1.0 repeatedly alternated
    between full teardown and full rebuild, not just a gain-value change. A
    monotonic one-direction sweep crosses the snap zone at most once, hence
    "clean"; oscillating near it can cross dozens of times a second, hence
    the popping and the apparent silence. Investigated and ruled out as
    contributing causes: the rebuild-loop guard can't trip here (`setSlider()`
    calls `resetRebuildLoopGuard()` on every invocation, before that same
    call's own rebuild is even counted - it structurally cannot accumulate
    across a live drag); and the new trap #24 listener doesn't fire
    spuriously off Sori's own aggregate churn (checked under both light and
    97-rebuild-heavy load, zero spurious fires either way).

    **Fixed two ways, both required:**
    - **Debounced teardown with hysteresis, not just retimed teardown.**
      When gain lands on exactly unity with no redirect, the tap is no
      longer torn down immediately - it's kept alive at gain 1.0 (a
      unity-gain tap passes audio through unmodified; costs a little CPU,
      audibly nothing) via `AppVolumeController.unityTeardownTimer`, a
      1.5s one-shot `Timer` (`.common` run loop mode, same
      NSEventTrackingRunLoopMode reasoning as every other timer in this
      project). Only torn down for real if gain stays at unity for the
      full debounce window. Any gain move off unity cancels the pending
      timer and the tap just keeps running at the new gain (the existing
      cheap live-update path). `performDebouncedTeardown` re-checks
      `needsTap` at FIRE time, not schedule time, so correctness doesn't
      depend on catching every path that could make a tap needed again
      (redirect changes, trap #24's listener) - only `applyGain()`
      explicitly cancels, as an optimization against a stray useless timer
      fire, not for correctness. `teardownTap()` itself unconditionally
      clears any pending timer too, regardless of which path reached it
      (the rebuild-loop guard, a redirect disconnecting while at unity),
      so a stale timer can never outlive the tap it was scheduled for.
      Scoped tightly to unity + no redirect + unmuted - a redirected or
      muted app at gain 1.0 still needs its tap regardless and is
      unaffected.
    - **Gain ramping in `ProcessAudioTapEngine.process()`, independent of
      the above.** `TapIOState` gained `previousGain` - exclusively
      audio-thread-owned (only `process()` itself reads or writes it; the
      external `gain` setter never touches it, so this adds no new
      cross-thread concern beyond what trap #22 already established for
      `gain`). Each callback now linearly ramps from `previousGain` to the
      current `gain` across the buffer's samples instead of jumping
      instantaneously - captured ONCE per callback (not per-channel), so a
      stereo pair ramps across the identical start/target pair and stays
      in sync, and `previousGain` only advances once, after every buffer
      this callback has been processed, to the actual target (not wherever
      the ramp mathematically landed on the last sample, which undershoots
      by one step by construction) - so a steady gain starts the next
      callback flat rather than perpetually "chasing" a target it's
      already effectively reached. Limiter engagement now checks
      `max(startGain, targetGain) > 1.0`, since either end of a ramp (not
      just a single scalar) can enter boost territory.

    **Verified live**, via the same temporary stress test re-run against
    the fix: the identical oscillation pattern that produced 97
    rebuilds/67 teardowns produced 18 rebuild-attempts/5 teardowns
    afterward - and every one of those 18 had `pids=[]`, meaning they were
    near-costless no-ops from the test harness's own synthetic pid churn
    (an `afplay` loop racing the 250ms poll), not real Core Audio object
    creation. Of 85 times the oscillation crossed unity, 84 were cancelled
    before the debounce fired; exactly ONE real teardown happened, 1.5s
    after the oscillation genuinely stopped - precisely the intended
    behavior. Confirmed no regression to boosted/limiter behavior
    separately (gain 1.8x, `/usr/bin/log stream` showed the same clean 1Hz
    "Limiter not engaged" cadence as before). **Not yet confirmed by ear**
    - the stress test proves the mechanism (rebuild counts, timing), not
    perceived audio quality; the user was going to listen-test fast
    slider drags (including across 100%) directly.

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

## Crash resilience & permission-flow notes (not Core Audio, kept separate
for the same reason as the section above - Swift/Foundation and TCC findings,
not Core Audio ones)

- **`Dictionary(uniqueKeysWithValues:)` fatal-traps on a duplicate key, and
  live OS enumeration is not guaranteed unique.** Confirmed live as a real,
  reproducible crash (`EXC_BREAKPOINT`/`SIGTRAP`, a Swift runtime trap, not
  memory corruption): `AudioProcessMonitor.refresh()` built a `[pid_t:
  NSRunningApplication]` map via `runningApps.map { ($0.processIdentifier,
  $0) }`, but `NSRunningApplication.processIdentifier` returns `-1` for an
  app that's transitioning in/out of existence - if two such apps are in
  that transient state during the same 250ms poll tick, both produce the key
  `-1` and the initializer traps. This crashed on the main thread, nowhere
  near Core Audio or the realtime IOProc callback - "runs fine for a while,
  then randomly dies" is exactly the signature of a bug gated on ambient
  system activity (something else launching/quitting at the right moment)
  rather than anything audio-specific. Fixed by filtering out `pid <= 0`
  entries before building the dictionary, then using `uniquingKeysWith:`
  (first-wins) as defense-in-depth, matching the pattern already used one
  line below for `runningAppsByName`. Audited the rest of the codebase for
  the same pattern (every other `Dictionary`/`Set` construction, every
  force-unwrap, `as!`, `try!`, `fatalError`, `precondition`) - this was the
  only instance.
- **`SoriDebugLog` must write to a persistent file, not just stderr, to be
  useful against a crash you can't reproduce on demand.** It's called from
  every tap/aggregate create-destroy, `AudioDeviceStart`/`Stop`/
  `CreateIOProcID`, device-list change, and rebuild-loop-guard trip - but a
  stderr-only log is invisible once the app launches normally (no attached
  terminal), and it was originally gated behind `SORI_DEBUG_TAP_LIFECYCLE=1`
  (off by default) - so it wouldn't have been capturing anything during
  whatever ordinary session actually crashes. Now always writes to
  `~/Library/Logs/Sori/sori.log` (5MB rotation, one backup) regardless of
  that env var, which still additionally mirrors to stderr for interactive
  debugging. Every call site is confirmed to run on the main actor (never
  from `ProcessAudioTapEngine.process(...)`, the realtime IOProc callback),
  so synchronous file I/O here is safe - a future call site added to that
  realtime callback would violate the realtime-thread rules regardless of
  what this logger does.
- **Once TCC has recorded ANY decision for `kTCCServiceAudioCapture`, macOS
  will never show the consent dialog again - not even after the user
  revokes a previous grant in System Settings.** `TCCAccessRequest` just
  silently replays the recorded decision. `AudioRecordingPermission.Status`
  already distinguishes this correctly since `TCCAccessPreflight` genuinely
  returns different codes for "never decided" (`.unknown`) vs. "a decision
  is on record" (`.denied` - covers both an initial refusal and a later
  revocation, macOS doesn't distinguish these to us either). The UI must
  route `.denied` to opening System Settings directly instead of calling
  `request()` again. The correct deep link, confirmed via Apple's own
  support documentation ("Control access to screen and system audio
  recording on Mac"), is:
  ```
  x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
  ```
  `Privacy_ScreenCapture` is the right anchor even though this permission is
  "System Audio Recording," not screen recording - Apple groups both under
  one shared pane, "Screen & System Audio Recording." Also per Apple's own
  guidance for that pane: toggling the switch there does **not** take effect
  until the app is fully quit and reopened, not just brought back to the
  foreground - `AudioRecordingPermission` already re-reads `TCCAccessPreflight`
  on `NSApplication.didBecomeActiveNotification`, so the *displayed* banner
  state will likely flip correctly without a relaunch, but that's just a
  database read and is not proof the running process's actual tap-creation
  capability re-took - tell the user explicitly to relaunch rather than
  relying on the banner disappearing as confirmation.

## Distribution (Sparkle auto-updates)

- Sparkle 2.9.4 via SPM (`project.yml` → `packages.Sparkle`, pinned in
  `sori.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).
  Sori has no entitlements and is not sandboxed (`ENABLE_HARDENED_RUNTIME: NO`,
  no `.entitlements` file), so the plain non-sandboxed Sparkle integration
  applies - no XPC service setup needed. If that ever changes (sandboxing
  gets added later), Sparkle's sandboxed-app XPC setup would need revisiting.
- **The EdDSA signing key is scoped to a Sori-specific keychain account,
  `com.sebastianzapata.sori`, not the tools' default account.** This
  machine's keychain already had a *different* app's (Grab's) Sparkle key
  under the default `ed25519` account - confirmed live via `generate_keys -p`
  before generating Sori's key, and reconfirmed both keys coexist
  independently afterward. Every Sparkle CLI invocation
  (`generate_keys`, `sign_update`) must pass `--account
  com.sebastianzapata.sori` explicitly, or it silently falls back to the
  default account instead of erroring - see `RELEASING.md` for the full
  command list.
- Sparkle's CLI tools (`generate_keys`, `sign_update`, `generate_appcast`,
  `BinaryDelta`) come from Sparkle's GitHub release tarball, not the SPM
  package (SPM only ships the framework) - unpacked at `.sparkle-tools/bin/`,
  gitignored.
- Feed model: `appcast.xml` is a plain file committed at the repo root,
  served via its `raw.githubusercontent.com` URL (`SUFeedURL` in
  `Info.plist`) - not a GitHub Release asset, since the feed URL needs to
  stay constant while its content grows across releases, which a single
  release's asset URL can't do on its own. Update *payloads* (the zipped
  app) are attached to GitHub Releases instead, referenced by the appcast's
  `<enclosure url>`. Note `raw.githubusercontent.com` caches for 5 minutes
  (`cache-control: max-age=300`) - after pushing an appcast change, the live
  URL can still serve the previous version for a few minutes; check
  `git show HEAD:appcast.xml` to confirm what was actually pushed rather
  than assuming the CDN response is current.
- **Builds are not notarized** (Apple Development signing identity, not
  Developer ID) - Gatekeeper will block both first install and every
  Sparkle-delivered update on any Mac other than the one it was built on.
  Full explanation and the right-click-Open workaround for end users is in
  `RELEASING.md`, not duplicated here.
- The actual release-cutting steps (version bump, build, `ditto` zip,
  `sign_update`, GitHub Release, appcast entry) live in `RELEASING.md`, not
  here - that file is the operational runbook, this file is codebase
  documentation.

## Style notes

- Comments explain *why*, especially "documented trap" reasoning discovered
  through live testing — not what the code obviously does.
- No AVAudioEngine (see above) — this is load-bearing, not a style
  preference; a future contributor reaching for it to "simplify" the tap
  engine will silently break audio capture.
- Prefer fixing the actual property/API resolution edge case over adding
  UI-layer workarounds — several bugs in this project turned out to be data
  resolution issues (Discord, Safari) that only *looked* like UI bugs.
