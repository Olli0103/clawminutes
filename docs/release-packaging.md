# Release packaging and permission identity

ClawMinutes still needs Developer ID credentials, real notarization and approved installed acceptance before public binary distribution. The source workflow below creates build artifacts only. It does not install, launch, reload or restart the helper or Gateway. The only helper subcommand invoked while packaging is `export-icon`, which renders supplied assets without capture or network.

## Local builds

Build the release executable with the supported Xcode toolchain:

```sh
npm run build:native
```

Choose a signing mode explicitly. No mode silently falls back to ad-hoc signing. Packaging never creates, unlocks, copies or recovers a keychain.

For a local certificate, run `python3 scripts/local-signing.py` separately only when you intend to create or unlock that identity. Supply the identity and the actual keychain path it reports:

```sh
npm run pack:helper -- --mode local \
  --identity 'ocmh local signing' \
  --keychain /path/to/your/local-signing.keychain-db
```

For an explicitly disposable development build:

```sh
npm run pack:helper -- --mode ad-hoc
```

Ad-hoc code identity can change with each build. Local signing is not Apple Developer ID signing or notarization. Neither mode establishes permission continuity or produces a notarized public release.

`--binary`, `--cloudflared` and `--output` select explicit inputs/output. `OPENCLAW_TEAMS_CLOUDFLARED` or PATH can supply cloudflared. Signing identity/keychain can come from `OPENCLAW_TEAMS_SIGNING_IDENTITY` and `OPENCLAW_TEAMS_SIGNING_KEYCHAIN`. The default output is the checkout's ignored `helper` directory. Installed helper paths and directories with runtime-state markers are refused.

## Developer ID distribution

Provision a Developer ID Application certificate and a `notarytool` credential profile locally using Apple's tooling. Keep private keys and passwords out of this repository and chat. The packager accepts an existing profile name, not a password. The following explicit mode uploads the staged app to Apple's service:

```sh
npm run pack:helper -- --mode developer-id \
  --identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --team-id YOURTEAMID \
  --notary-profile YOUR_EXISTING_PROFILE
```

The script signs cloudflared before the outer app, enables hardened runtime and a secure timestamp, and applies the helper's audio-input entitlement. It rejects extra release entitlements. It verifies the Developer ID Application certificate type, Apple trust chain and requested team for both code items. Displaying a certificate name alone is insufficient.

It submits a temporary app ZIP, requires an `Accepted` JSON response, staples and validates the ticket, rechecks signatures and runs Gatekeeper assessment. Only then does it create the final distribution ZIP with `ditto` to preserve ticket/resource metadata. Failure at any gate preserves previous published artifacts. No npm package, GitHub release or installed service is published or changed by this command.

This is an implemented source path. Actual Developer ID signing, credential access, Apple acceptance, ticket preservation through distribution, Gatekeeper behavior and microphone/Core ML behavior under hardened runtime remain `needs_evidence` until executed with real credentials. A stubbed command test proves control flow only.

Apple's primary references explain [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), [notarization and stapling](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), and [the audio-input entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input).

## Output and failure handling

Inputs, bundle identity, lifecycle support and version are checked before replacing any artifact. A per-output lock serializes packagers. The candidate app, icons, notices, signing and ZIP are prepared in a separate stage. Ordinary publication failure restores the previous app and ZIP. If rollback itself fails, backups stay in the stage for manual recovery. A hard crash can also leave a partial stage or mismatched published pair. A later packaging attempt refuses these stages until a person reviews/restores them. This is not a filesystem transaction or a power-loss guarantee.

The final outputs are `helper/ocmh.app` and `helper/recording-mac.zip`. The ZIP contains the app and `scripts/helper.py`. The npm `files` whitelist admits only those two helper artifacts, so interrupted stages, backups, packaging locks and unrelated helper files cannot enter the npm archive. Notices and source remain included separately. Use `npm pack --dry-run --ignore-scripts --json` to inspect membership before a release. Artifact hashes printed by the packager identify output bytes; they do not establish reproducible-build provenance or verify live behavior.

A source checkout's binary must be rebuilt before packaging. The packager does not claim that an arbitrary `--binary` came from the current Git commit. Real release provenance must retain the clean source commit, build command/toolchain, signing results, final hashes and acceptance record together.

## Checking permission identity

Read-only verification can compare two builds:

```sh
python3 scripts/check-signature.py --app /path/to/new/ocmh.app \
  --reference /path/to/previous/ocmh.app
```

The command verifies both code seals before comparing their designated requirements. It rejects hash-only requirements. Without `--reference`, it verifies a single app and reports that no changing hash requirement was found. Neither result proves that macOS retained actual permission grants. Apple describes how [designated requirements identify authorized apps](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Before broader use, perform an approved fresh-Mac installation and two signed updates. Check the actual microphone, system-audio and Accessibility grants, safe capture, reconnect/recovery, no premature recording and full transcript/notes delivery after each update. Use the same bundle identity, signing lineage and supported install path. Switching from local/ad-hoc signing to Developer ID changes the authorization identity and may require new grants. Never restart or update an installed helper/Gateway without explicit approval, and never interrupt active recording.
