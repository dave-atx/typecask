# Releasing

App builds go to TestFlight from GitHub Actions. Push a `testflight-N` tag and the **TestFlight**
workflow (`.github/workflows/testflight.yml`) fetches the pinned fonts, archives, exports and uploads
build `N`. Each upload needs a new `N`, or App Store Connect rejects it as a duplicate.

The fonts it ships are whatever `Typecask/FontsAsset.json` pins; see
[the font pipeline](font-pipeline.md#publishing-fonts).

## Check the fonts

App Store Connect validates every font in the upload, including those in asset packs, at the `strict`
level because the app has the Fonts capability, and rejects the build (ITMS-90792) for any one that
fails. macOS 27.2 and later include the same validator, `FontValidator` 3.5, and
`scripts/check-fonts.sh` runs it on the previews and the unpacked `Fonts.xcassets`: the sources,
not the built app, whose asset catalogs it can't read. It prints each font it would reject and fails.

```sh
scripts/check-fonts.sh               # Previews/, ApplePreviews/ and Fonts.xcassets
scripts/check-fonts.sh path/to/fonts # or any directories or files
```

The Fonts workflow runs it on the whole archive before publishing, and the TestFlight workflow before
archiving. On an older macOS, which GitHub's `xcode-27` image was at 27.0.1, it warns on the run and
checks nothing, so check on a Mac with 27.2 before tagging until the image catches up. See Apple's
[TN3214](https://developer.apple.com/documentation/technotes/tn3214-validating-the-fonts-you-ship-in-your-app),
and `LEFT_OUT_FILES` in [the font pipeline](font-pipeline.md#what-a-release-ships) for a cask's file
that fails upstream.

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

## App Store images

`scripts/screenshots.sh app-store` takes the screenshots on a 6.9-inch iPhone, a 13-inch iPad and an iPhone
Duo simulator into `AppStoreScreenshots/raw/`, then lays them out as the images App Store Connect takes, in
a folder per screenshot slot:

| Folder | Slot | Size (px) |
| --- | --- | --- |
| `iphone-medium/` | iPhone with Dynamic Island (medium display), required | 1206 x 2622 |
| `iphone-large/` | iPhone with Dynamic Island (large display) | 1320 x 2868 |
| `ipad/` | iPad 13-inch display, required | 2752 x 2064 |
| `duo-outer/` | iPhone Duo outer display | 1398 x 2034 |
| `duo-inner/` | iPhone Duo inner display, landscape | 2853 x 2007 |

plus `header.png` (3840 x 1646) and `search-results.png` (3840 x 2560) for the product page header and
search results. App Store Connect refuses an image in a slot that wants other dimensions.

The Duo runs twice: folded, onto the outer display, then unfolded with `idb hinge 180`, since neither
`simctl` nor XCTest can set the hinge. So `app-store` needs idb. Unfolded, the app lays out like an iPad,
sidebar and gallery, in landscape.

Each image is a page in `scripts/app-store/`, drawn by headless Google Chrome at its CSS size times a scale,
and run through oxipng, which also drops the alpha channel App Store Connect refuses. The pages load their
fonts from Google Fonts, so rendering needs the network.

After changing a page, `scripts/screenshots.sh app-store-render` redraws the images from the shots already
taken, in under a minute, without the simulator. `AppStoreScreenshots/` is gitignored; upload each folder's
PNGs by hand.
