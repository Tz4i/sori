import AppKit
import Foundation
import SwiftUI

// 소리 (Sori) is a menu bar-only (LSUIElement) agent app. No main window.
//
// NOTE: audio capture in this project must go through the Core Audio process
// tap APIs (AudioHardwareCreateProcessTap), NOT AVAudioEngine. Do not add an
// AVAudioEngine dependency in later steps.
@main
struct SoriApp: App {
    // Plain `let`, not `@State`: these are app-lifetime singletons, not
    // view-identity-scoped state. `@State` only installs its stored default
    // value once the view hierarchy actually mounts it, and MenuBarExtra
    // content is generally built lazily (the first time the dropdown opens),
    // so an `@State`-wrapped AudioProcessMonitor's timer wouldn't start
    // polling until the user clicked the icon at least once. A plain `let` is
    // constructed right here, at App-struct init time, so monitoring begins
    // immediately at launch regardless of whether the dropdown's ever opened.
    private let permission = AudioRecordingPermission()
    private let availableDevices: AvailableAudioDevices
    private let processMonitor: AudioProcessMonitor
    private let systemOutput: SystemDeviceVolumeController
    private let systemInput: SystemDeviceVolumeController
    private let systemAlert = SystemAlertVolumeController()

    init() {
        let availableDevices = AvailableAudioDevices()
        self.availableDevices = availableDevices
        self.processMonitor = AudioProcessMonitor(availableDevices: availableDevices)
        self.systemOutput = SystemDeviceVolumeController(kind: .output, availableDevices: availableDevices)
        self.systemInput = SystemDeviceVolumeController(kind: .input, availableDevices: availableDevices)

        if ProcessInfo.processInfo.environment["SORI_CHECK_TCC"] == "1" {
            FileHandle.standardError.write("SORI_TCC_STATUS=\(permission.status.rawValue)\n".data(using: .utf8)!)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["SORI_REQUEST_TCC"] == "1" {
            FileHandle.standardError.write("SORI: pre-request status=\(permission.status)\n".data(using: .utf8)!)
            permission.request()
        }
        TapEngineDiagnosticTest.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                permission: permission,
                processMonitor: processMonitor,
                availableDevices: availableDevices,
                systemOutput: systemOutput,
                systemInput: systemInput,
                systemAlert: systemAlert
            )
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        // .menu style renders content as a real NSMenu, and NSMenuItem-hosted
        // views don't support draggable controls like Slider (confirmed live:
        // the slider rendered but couldn't be dragged). .window style backs
        // the dropdown with a real NSHostingView-backed window instead, which
        // supports full SwiftUI interactivity.
        .menuBarExtraStyle(.window)
    }

    /// A distinctive-but-native monochrome template mark - three rounded
    /// vertical bars (an "equalizer" glyph), deliberately different from the
    /// generic sine-wave "waveform" SF Symbol used before. Built
    /// programmatically rather than as an Assets.xcassets entry so there's
    /// no xcodegen/asset-catalog wiring to keep in sync. `isTemplate = true`
    /// is what makes AppKit auto-tint this correctly for light/dark menu
    /// bars and menu bar tinting/vibrancy, exactly like a stock SF Symbol.
    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2.5
            let heights: [CGFloat] = [8, 15, 11]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
            var x = rect.midX - totalWidth / 2
            for height in heights {
                let barRect = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Fixed popover width - only the Applications list's height is allowed to
/// vary (see `maxVisibleApps` below), so the width never needs to.
private let popoverWidth: CGFloat = 300

/// The Applications list grows to fit up to this many rows before it starts
/// scrolling instead. Re-tests a previously-documented trap: MenuBarExtra's
/// `.window` style was confirmed live to NOT reliably re-measure its hosting
/// NSWindow when SwiftUI content's ideal size changed later from a
/// background update (as opposed to direct user interaction) - a new app
/// row appearing while the dropdown was already open looked exactly like "a
/// second app replaces the first." That was on an earlier macOS build;
/// re-verified live on this one before shipping this change (see
/// PROGRESS.md) rather than assuming the old finding still holds.
private let maxVisibleApps = 5
/// Estimated height of one `AudioAppRow`, used only to cap the ScrollView -
/// not pixel-precise, just enough to keep roughly `maxVisibleApps` rows
/// visible before scrolling kicks in.
private let estimatedAppRowHeight: CGFloat = 56

private struct MenuContentView: View {
    var permission: AudioRecordingPermission
    var processMonitor: AudioProcessMonitor
    var availableDevices: AvailableAudioDevices
    var systemOutput: SystemDeviceVolumeController
    var systemInput: SystemDeviceVolumeController
    var systemAlert: SystemAlertVolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                switch permission.status {
                case .authorized:
                    Label("Audio permission granted", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .denied, .unknown:
                    Button("Grant Audio Permission…") {
                        permission.request()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "System")
                    SystemVolumeRow(title: "Output", systemImage: "speaker.wave.2.fill", controller: systemOutput)
                    SystemVolumeRow(title: "Input", systemImage: "mic.fill", controller: systemInput)
                    SystemAlertVolumeRow(controller: systemAlert)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Applications")
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if processMonitor.entries.isEmpty {
                    Text("No apps playing audio")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                } else if processMonitor.entries.count > maxVisibleApps {
                    // More rows than fit - cap the ScrollView's height so it
                    // scrolls instead of growing the window past a
                    // reasonable size.
                    ScrollView {
                        appRows
                    }
                    .frame(height: CGFloat(maxVisibleApps) * estimatedAppRowHeight)
                } else {
                    // Few enough rows to just size to content - no
                    // ScrollView at all, so the popover's own ideal height
                    // (and therefore the window) grows and shrinks with the
                    // list.
                    appRows
                }
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit Sori")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: popoverWidth)
        // System material, not a flat fill, so the popover blurs like a
        // native menu (`.regularMaterial` already respects Reduce
        // Transparency and Increase Contrast automatically - no extra
        // accessibility handling needed here). Continuous corner radius
        // matches the rounded-rect style macOS itself uses for floating
        // panels and popovers.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var appRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(processMonitor.entries) { entry in
                if let controller = processMonitor.volumeControllers[entry.bundleIdentifier] {
                    AudioAppRow(entry: entry, controller: controller, availableDevices: availableDevices)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AudioAppRow: View {
    let entry: AudioAppEntry
    let controller: AppVolumeController
    let availableDevices: AvailableAudioDevices

    /// True while the slider is past unity and actually audible - used to
    /// give boost territory a subtle, native-feeling (system orange tint)
    /// visual cue rather than leaving 100%-200% looking identical to
    /// 0%-100%.
    private var isBoosted: Bool { controller.sliderGain > 1.0 && !controller.isMuted }

    /// Snaps any slider drag landing within ±4% of 1.0 exactly onto 1.0 -
    /// SwiftUI's Slider has no native detent, so this is the practical way to
    /// make 100% easy to hit on a continuous 0...2 range.
    private var snappingGain: Binding<Float> {
        Binding(
            get: { controller.sliderGain },
            set: { newValue in
                let snapped = abs(newValue - 1.0) < 0.04 ? 1.0 : newValue
                controller.setSlider(snapped)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = entry.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        // 50% matches AppKit's own conventional dimmed-icon
                        // treatment (e.g. Finder's cut/hidden-item icons) -
                        // not a hand-picked number - while still reading
                        // clearly as "remembered, not currently playing"
                        // rather than fully hidden.
                        .opacity(entry.isActive ? 1.0 : 0.5)
                }
                Text(entry.displayName)
                    .lineLimit(1)
                    .foregroundStyle(entry.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                Text(controller.isMuted ? "Muted" : "\(Int((controller.sliderGain * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isBoosted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            HStack(spacing: 8) {
                Slider(value: snappingGain, in: 0...2)
                    .tint(isBoosted ? .orange : .accentColor)
                    .disabled(controller.isMuted)
                RedirectDeviceMenu(controller: controller, availableDevices: availableDevices)
                Button {
                    controller.toggleMute()
                } label: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The per-app "Redirect Audio To" control - a small icon-triggered menu
/// (not a full text Picker) so the row's width stays constant regardless of
/// device name length, matching the fixed-size popover constraint. Three
/// visible-at-a-glance icon states, not just "opened menu shows detail":
/// outline at "No Redirect", filled+normal while the redirect target is
/// actually connected, filled+orange (with a tooltip) while the user has a
/// redirect target set but it's currently disconnected - falling back to
/// system output underneath, same as "No Redirect" would, but visibly
/// distinct from actually being unredirected.
private struct RedirectDeviceMenu: View {
    let controller: AppVolumeController
    let availableDevices: AvailableAudioDevices

    var body: some View {
        Menu {
            Button {
                controller.setRedirectDevice(uid: nil, name: nil)
            } label: {
                checkmarkLabel("No Redirect", isSelected: controller.redirectDeviceUID == nil)
            }

            if !availableDevices.outputDevices.isEmpty {
                Divider()
                ForEach(availableDevices.outputDevices) { device in
                    Button {
                        controller.setRedirectDevice(uid: device.uid, name: device.name)
                    } label: {
                        checkmarkLabel(device.name, isSelected: controller.redirectDeviceUID == device.uid)
                    }
                }
            }

            if controller.isRedirectPending {
                Divider()
                Label("\(controller.redirectDeviceDisplayName ?? "Selected device") (unavailable)", systemImage: "exclamationmark.triangle")
            }
        } label: {
            Image(systemName: controller.redirectDeviceUID == nil ? "airplayaudio" : "airplayaudio.circle.fill")
                .foregroundStyle(controller.isRedirectPending ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .frame(width: 16)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            controller.isRedirectPending
                ? "\(controller.redirectDeviceDisplayName ?? "Redirect target") is disconnected - using system output for now"
                : ""
        )
    }

    private func checkmarkLabel(_ title: String, isSelected: Bool) -> some View {
        deviceMenuItemLabel(title, isSelected: isSelected)
    }
}

/// Shared menu-item label for device-picker `Menu`s: a checkmark next to
/// whichever option is currently selected, plain text otherwise.
@ViewBuilder
private func deviceMenuItemLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
        Label(title, systemImage: "checkmark")
    } else {
        Text(title)
    }
}

/// Native grouped-list-style section header - small, secondary, uppercase
/// (matching e.g. Finder sidebar section labels), not styled as a row.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

/// One row in the System section for a hardware device's own volume (OUTPUT
/// or INPUT) - greyed out (standard disabled-control styling, not hidden)
/// when the current default device has no adjustable volume property at
/// all.
private struct SystemVolumeRow: View {
    let title: String
    let systemImage: String
    let controller: SystemDeviceVolumeController

    private var labelStyle: AnyShapeStyle {
        controller.isSupported ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(labelStyle)
                Text(title)
                    .foregroundStyle(labelStyle)
                Spacer()
                Text(controller.isSupported ? "\(Int((controller.sliderGain * 100).rounded()))%" : "—")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                // 0...1 only - this row has no boost region, so 100% sits at
                // the far right of the track rather than the midpoint of a
                // wider range that would otherwise look truncated/broken.
                Slider(
                    value: Binding(
                        get: { controller.sliderGain },
                        set: { controller.setSlider($0) }
                    ),
                    in: 0...1
                )
                .disabled(!controller.isSupported)

                if !controller.deviceOptions.isEmpty {
                    SystemDeviceMenu(controller: controller)
                }
            }
        }
    }
}

/// Device picker for the System Output/Input rows - same compact
/// icon-triggered `Menu` pattern as `RedirectDeviceMenu`, but always picks
/// the system-wide default device (`selectDevice`) rather than an app-scoped
/// redirect, and has no "No Redirect" option since a default device is
/// always some concrete device.
private struct SystemDeviceMenu: View {
    let controller: SystemDeviceVolumeController

    var body: some View {
        Menu {
            ForEach(controller.deviceOptions) { device in
                Button {
                    controller.selectDevice(uid: device.uid)
                } label: {
                    deviceMenuItemLabel(device.name, isSelected: controller.currentDeviceUID == device.uid)
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .frame(width: 16)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The System section's SOUND EFFECTS row - macOS's alert/UI sound volume,
/// independent of main output. See `SystemAlertVolumeController` for how
/// this is actually driven (not a Core Audio property - AppleScript's "set
/// volume alert volume" is the only working surface, found live). Volume
/// only, no device picker - alert sounds don't have a separate routable
/// device the way output/input do.
private struct SystemAlertVolumeRow: View {
    let controller: SystemAlertVolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .frame(width: 16)
                Text("Sound Effects")
                Spacer()
                Text("\(Int((controller.sliderGain * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { controller.sliderGain },
                    set: { controller.setSlider($0) }
                ),
                in: 0...1
            )
        }
    }
}
