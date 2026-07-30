import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` - constructed
/// once at app-lifetime scope, same as every other controller in `SoriApp`,
/// so automatic background checks start immediately at launch rather than
/// waiting for the popover to be opened at least once.
///
/// All of Sparkle's actual policy - daily automatic checks, prompting before
/// installing rather than silently installing, the feed URL, and the EdDSA
/// public key - comes from Info.plist (`SUFeedURL`, `SUPublicEDKey`,
/// `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`,
/// `SUAutomaticallyUpdate`), so there's nothing further to configure here.
/// `SPUStandardUpdaterController` wires in Sparkle's own standard user driver
/// (`SPUStandardUserDriver`), which handles all of the checking/up-to-date/
/// download-available UI itself - this works fine for an `LSUIElement` app
/// with no other windows, since Sparkle presents its own floating windows
/// regardless of dock/menu-bar presentation.
///
/// Sori is not sandboxed (no entitlements, `ENABLE_HARDENED_RUNTIME: NO` -
/// see CLAUDE.md), so none of Sparkle's sandboxed-app XPC service setup
/// applies; this is the plain, non-sandboxed integration path.
///
/// See RELEASING.md for how to actually cut and publish a release.
final class SoriUpdaterController {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Wired to the "Check for Updates…" item in the gear settings menu.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
