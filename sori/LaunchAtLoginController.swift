import Foundation
import Observation
import OSLog
import ServiceManagement

/// Backs the "Launch 소리 at Login" toggle with `SMAppService.mainApp` - the
/// macOS 13+ replacement for the deprecated `SMLoginItemSetEnabled` and for
/// hand-rolled `LaunchAgents` plists. `SMAppService.mainApp` registers/
/// unregisters this exact app bundle directly; unlike the old API, no
/// separate helper-app login-item target is needed.
///
/// Default is OFF and stays that way until the user acts: nothing in this
/// class calls `register()` except `isEnabled`'s setter, which only runs in
/// response to the toggle - `init()` only ever *reads* `status`, it never
/// registers on its own.
///
/// `status` is not this app's own state to own - the system is the source of
/// truth (the user can remove/pause it directly in System Settings > General
/// > Login Items, outside Sori entirely), so this is a thin, re-readable
/// reflection of `SMAppService.mainApp.status`, same philosophy as
/// `SystemDeviceVolumeController` toward hardware volume. `refreshStatus()`
/// is called when the popover opens so a change made in System Settings
/// while Sori wasn't looking is picked up rather than showing stale state.
@MainActor
@Observable
final class LaunchAtLoginController {
    private let logger = Logger(subsystem: "com.sebastianzapata.sori", category: "LaunchAtLoginController")

    private(set) var status: SMAppService.Status

    /// True once `register()` succeeds but macOS hasn't yet had the user
    /// approve it in System Settings - the toggle itself should still read
    /// "on" (the registration succeeded, from Sori's side there's nothing
    /// left to do), but the row shows a hint pointing at where to finish it,
    /// rather than failing silently and leaving the user wondering why login
    /// items looks empty.
    var needsApprovalHint: Bool { status == .requiresApproval }

    init() {
        status = SMAppService.mainApp.status
    }

    /// Re-reads live system state. Call when the popover opens - the user
    /// may have toggled this in System Settings > General > Login Items
    /// directly (removed it, or resolved a pending approval) since Sori last
    /// checked, and there's no listener/notification for this the way there
    /// is for Core Audio properties.
    func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    /// `.requiresApproval` still counts as "on" for the toggle - the
    /// registration itself succeeded; approval is a separate, user-visible
    /// step macOS gates on, not something Sori failed to do.
    var isEnabled: Bool {
        get { status == .enabled || status == .requiresApproval }
        set {
            if newValue {
                register()
            } else {
                unregister()
            }
        }
    }

    /// Opens System Settings directly to the Login Items & Extensions pane -
    /// the officially supported way to guide the user to the approval step
    /// (added alongside `SMAppService` itself), rather than a hand-built
    /// `x-apple.systempreferences:` URL that could silently break across
    /// System Settings redesigns.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        do {
            try SMAppService.mainApp.register()
            status = SMAppService.mainApp.status
            logger.notice("Registered as login item, status=\(String(describing: self.status), privacy: .public)")
        } catch {
            status = SMAppService.mainApp.status
            logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            status = SMAppService.mainApp.status
            logger.notice("Unregistered login item")
        } catch {
            status = SMAppService.mainApp.status
            logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
