# Releasing

App builds go to TestFlight from GitHub Actions. Push a `testflight-N` tag and the **TestFlight**
workflow (`.github/workflows/testflight.yml`) fetches the pinned fonts, archives, exports and uploads
build `N`. Each upload needs a new `N`, or App Store Connect rejects it as a duplicate.

The fonts it ships are whatever `Typecask/FontsAsset.json` pins; see
[the font pipeline](font-pipeline.md#publishing-fonts).

## Setup

It needs an Apple Developer Program membership, an App Store Connect record for the app's bundle ID
whose App ID has the Fonts capability ("Install Fonts"), and these in the repository's Actions
settings:

| Name | Kind | What it is |
| --- | --- | --- |
| `APPLE_TEAM_ID` | variable | the ten-character team the app signs with |
| `APPLE_DISTRIBUTION_CERT_P12` | secret | `base64 -i cert.p12` of an Apple Distribution certificate and its key, exported from Keychain Access's My Certificates |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | secret | the password that export was given |
| `APPLE_PROVISIONING_PROFILE` | secret | `base64 -i profile.mobileprovision` of an App Store profile for the bundle ID |
| `APP_STORE_CONNECT_KEY_ID` | secret | an App Store Connect API key with App Manager access |
| `APP_STORE_CONNECT_ISSUER_ID` | secret | that key's issuer, from the same page |
| `APP_STORE_CONNECT_PRIVATE_KEY` | secret | the key's `.p8`, contents and all |

The project names no signing team. `Signing.xcconfig` includes an optional, gitignored
`Signing.local.xcconfig`, which the workflow writes from `APPLE_TEAM_ID`, and which you can write
yourself to archive locally.

## Why signing is manual

Given an App Store Connect API key, `xcodebuild -allowProvisioningUpdates` signs distribution builds
with Apple's cloud-managed certificates, and an API key has no access to those. So the archive is signed
ad hoc (`CODE_SIGN_IDENTITY=-`), and `xcodebuild -exportArchive` re-signs the app and every asset pack
with the certificate and profile from the secrets above. The API key is still used to upload.

`scripts/prepare-export.sh` installs the profile, writes the matching `ExportOptions.plist`, and checks
the profile's team, App ID, expiry and wildcard-ness and that a distribution identity is in the
keychain. It runs before the archive, because xcodebuild reports signing problems only once it reaches
signing, after the long archive step. The certificate goes into a keychain of the job's own, which the
last step deletes along with the profile.

An export prints almost nothing when it fails. Its detail is in the `.xcdistributionlogs` bundle named
on the first line of its output.

## After the upload

A green run doesn't mean the build is in TestFlight yet. `altool` returns once Apple has the bytes, and
App Store Connect then processes them, which takes several minutes before the build appears under
Builds. A build that never appears has failed processing, and Apple reports that by email.
