# Releasing 소리 (Sori)

How to cut and publish a Sparkle-delivered update. Read this instead of
rediscovering the process each time.

## One-time setup (already done, documented here for reference)

- Sparkle 2.9.4 added via SPM (`project.yml` → `packages.Sparkle`).
- A dedicated EdDSA signing key pair was generated for Sori specifically -
  **not** shared with any other app - using:
  ```
  generate_keys --account com.sebastianzapata.sori
  ```
  The private key lives only in this Mac's login keychain, under that account
  name (`security find-generic-password -s "https://sparkle-project.org" -a
  com.sebastianzapata.sori` if you ever need to confirm it's there). The
  public key is embedded in `sori/Info.plist` as `SUPublicEDKey`.
- **The private key must never be committed, exported to a file, pasted into
  chat, or shared.** `generate_keys -x` would export it - don't run that
  unless you're deliberately moving to a new Mac and know what you're doing.
  If it's ever lost, generate a new key pair (same command) and update
  `SUPublicEDKey` - existing installs on the old key just won't get the new
  update signed correctly, so treat regenerating as a last resort, not a
  routine action.
- `--account com.sebastianzapata.sori` must be passed to **every** Sparkle
  CLI tool invocation below (`sign_update`, and `generate_keys -p` if you
  need to re-print the public key) - without it, the tools fall back to the
  keychain's default `ed25519` account, which on this Mac belongs to a
  different app (Grab).
- Sparkle's CLI tools (`generate_keys`, `sign_update`, `generate_appcast`,
  `BinaryDelta`) come from Sparkle's GitHub release tarball, not the SPM
  package (SPM only ships the framework). They're unpacked at
  `.sparkle-tools/bin/` in this repo, gitignored. Re-fetch for a newer
  Sparkle version with:
  ```
  curl -fsSL -o Sparkle.tar.xz \
    "https://github.com/sparkle-project/Sparkle/releases/download/<version>/Sparkle-<version>.tar.xz"
  tar -xf Sparkle.tar.xz -C .sparkle-tools
  ```
- Appcast is hosted as a plain file committed to this repo (`appcast.xml` at
  the root), served via its raw.githubusercontent.com URL on `main`. `SUFeedURL`
  in Info.plist points at that URL. The actual update *binaries* (zips) are
  attached to GitHub Releases, referenced by the appcast's `<enclosure url>`.
  This split (feed = committed file, payload = release asset) is the standard
  Sparkle-on-GitHub pattern: the feed URL needs to stay constant and always
  contain every still-relevant version, which a single release's asset URL
  can't do on its own.

## ⚠️ Builds are NOT notarized

Sori is currently signed with the "Apple Development" identity (see
CLAUDE.md), not a Developer ID Application certificate, and nothing in this
release process runs Apple's notarization service or staples a ticket to the
build. Concretely, this means: **on any Mac other than the one it was built
on, both the first install AND every single Sparkle-delivered update will
trigger Gatekeeper**, showing something like:

> "Sori" cannot be opened because Apple cannot check it for malicious
> software.

This is not a bug in the Sparkle setup - it's expected given there's no
notarization step, and it will keep happening on every future update too,
not just the first install, until that's fixed.

**Workaround to tell users about**, until notarization is set up:
1. In Finder, right-click (or Control-click) `Sori.app` and choose **Open**
   from the context menu - this shows the same warning but with an **Open**
   button, which plain double-clicking doesn't offer.
2. If that's not available, open **System Settings → Privacy & Security**,
   scroll to the Security section, and click **Open Anyway** next to the
   message about Sori being blocked.
3. This only needs to happen once per build - Gatekeeper remembers the
   decision for that specific binary, but a *new* build (i.e. every update)
   presents the same warning again fresh, since it's a different binary.

**The real fix, if frictionless distribution ever matters:** enroll in the
Apple Developer Program (if not already), sign with a Developer ID
Application certificate instead of Apple Development, and add a
notarization step (`xcrun notarytool submit ... --wait` followed by `xcrun
stapler staple sori.app`) to this release process before zipping. That's a
separate, later project from this Sparkle setup - not required for Sparkle
itself to work, just for it to work *without* the Gatekeeper prompt on other
people's Macs.

## Cutting a release

1. **Bump the version** in `sori/Info.plist`:
   - `CFBundleShortVersionString` - the human-facing marketing version, e.g.
     `1.1`. This is what `sparkle:shortVersionString` in the appcast will
     show users.
   - `CFBundleVersion` - a plain incrementing integer build number, e.g. `2`.
     This is what Sparkle actually compares to decide "is there a newer
     version" (`sparkle:version` in the appcast) - it must strictly increase
     every release, marketing version bump or not.

2. **Regenerate the Xcode project** if any source files or `project.yml`
   changed since the last release (harmless no-op otherwise):
   ```
   xcodegen generate
   ```

3. **Build a Release configuration**:
   ```
   export DEVELOPER_DIR=/Volumes/Untitled/Xcode-beta.app/Contents/Developer
   xcodebuild -project sori.xcodeproj -scheme sori -configuration Release \
     -destination 'platform=macOS' -allowProvisioningUpdates build
   ```
   The built `sori.app` lands in
   `~/Library/Developer/Xcode/DerivedData/sori-*/Build/Products/Release/`.

   Note: this is signed with the "Apple Development" identity, not a
   Developer ID, and isn't notarized - see the "⚠️ Builds are NOT notarized"
   section above for what that means for anyone installing on a different
   Mac.

4. **Zip the app** with `ditto` (not plain `zip` - `ditto` preserves the code
   signature and resource fork correctly):
   ```
   cd ~/Library/Developer/Xcode/DerivedData/sori-*/Build/Products/Release
   ditto -c -k --sequesterRsrc --keepParent sori.app sori-1.1.zip
   ```

5. **Sign the zip** with Sparkle's `sign_update`:
   ```
   /Users/sebas/sori/.sparkle-tools/bin/sign_update --account com.sebastianzapata.sori sori-1.1.zip
   ```
   This prints something like:
   ```
   sparkle:edSignature="MC0CFQ...base64...=" length="1234567"
   ```
   Copy both attributes - they go straight into the appcast `<enclosure>` tag
   in the next step.

6. **Create the GitHub Release and upload the zip** (do this *before*
   touching `appcast.xml` - the appcast needs a real, live download URL to
   point at):
   ```
   gh release create v1.1 sori-1.1.zip \
     --title "소리 1.1" \
     --notes "What changed in this release."
   ```
   This gives you a stable download URL of the form:
   ```
   https://github.com/Tz4i/sori/releases/download/v1.1/sori-1.1.zip
   ```

7. **Add a new `<item>` to `appcast.xml`** (see template below), using the
   signature/length from step 5 and the download URL from step 6. New items
   go at the top of the list (newest first, for human readability - Sparkle
   itself just picks whichever qualifying version is highest, order doesn't
   affect behavior).

8. **Commit and push `appcast.xml`** (and the version-bumped `Info.plist` /
   regenerated `project.pbxproj` if changed) to `main` last, once the release
   asset is confirmed live - this is the step that actually starts offering
   the update to everyone already running Sori:
   ```
   git add sori/Info.plist sori.xcodeproj/project.pbxproj appcast.xml
   git commit -m "Release 1.1"
   git push
   ```

9. **Verify**: open Sori, gear menu → "Check for Updates…", confirm it finds
   1.1 and offers to install it.

## appcast.xml format

Sparkle's appcast is an RSS 2.0 feed with a `sparkle:` namespace for the
update-specific fields. Full reference:
<https://sparkle-project.org/documentation/publishing/>.

Real example entry (this is literally what a 1.1 entry over the current 1.0
would look like, with placeholder signature/length):

```xml
<item>
    <title>Version 1.1</title>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
    <description><![CDATA[
        <ul>
            <li>Fixed a rare crash on launch.</li>
            <li>Added Launch at Login.</li>
        </ul>
    ]]></description>
    <pubDate>Thu, 30 Jul 2026 12:00:00 -0700</pubDate>
    <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/Tz4i/sori/releases/download/v1.1/sori-1.1.zip"
        length="1234567"
        type="application/octet-stream"
        sparkle:edSignature="MC0CFQ...base64...=" />
</item>
```

Field notes:
- `sparkle:version` - the build number (`CFBundleVersion`). This is the
  number Sparkle actually compares against the installed app's version to
  decide if this is newer. Must strictly increase every release.
- `sparkle:shortVersionString` - the marketing version (`CFBundleShortVersionString`).
  Optional if you don't ever bump the build number and marketing version
  independently, but Sori's do move together, so always include both.
- `description` - inline release notes shown in Sparkle's update dialog;
  wrap in `CDATA` so you can use HTML markup.
- `enclosure url` - must match the GitHub Release asset's download URL
  exactly, and the file at that URL must have been zipped with `ditto` from
  the exact same build you ran `sign_update` against - the signature is over
  the zip's bytes.
- `sparkle:edSignature` / `length` - straight from `sign_update`'s output in
  step 5 above. Don't hand-edit these.
- `sparkle:minimumSystemVersion` - kept in sync with `LSMinimumSystemVersion`
  in Info.plist (currently `14.4`).

New items are added to the top of `<channel>`, above older ones - older items
can be kept indefinitely (they let Sparkle offer an intermediate update to
someone on a very old version, if delta updates aren't set up) or pruned
periodically; neither is required for Sparkle to function correctly.
