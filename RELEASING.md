# Releasing Herdrbar

`Scripts/release.sh` builds a release on your Mac. It publishes nothing. The only file it changes in Git is
`appcast.xml`, the update feed.

## Build

1. Set `MARKETING_VERSION` and a higher `BUILD_NUMBER` in `version.env`, then commit.
2. Run `Scripts/release.sh`.

It needs a clean checkout, the Developer ID certificate in the login Keychain, and the `AC_PASSWORD`
notarytool profile. Set `APP_IDENTITY`, `TEAM_ID`, or `NOTARY_PROFILE` when yours differ.

The script runs the tests, builds for Apple silicon and Intel, signs with the hardened runtime, notarizes,
staples, and checks the app with Gatekeeper. `release/VERSION/` then holds:

- `Herdrbar-VERSION.zip`: the notarized app.
- `Herdrbar-VERSION.dmg`: the same app on a notarized disk image, beside a link to Applications.
- `herdrbar.rb`: the Homebrew cask, with the zip's SHA-256.
- `SHA256SUMS`: checksums for all three.

It also adds the zip to `appcast.xml`, signed with the Sparkle EdDSA key in the login Keychain. That key is
shared with your other apps, and its public half is `SUPublicEDKey` in `Scripts/package_app.sh`. The first run
asks for access to the Keychain: choose Always Allow. If the private key is lost, installed copies can never
update again, so keep an export of it (`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x FILE`).

## Publish

```sh
gh release create v0.1.0 release/0.1.0/Herdrbar-0.1.0.{zip,dmg} release/0.1.0/SHA256SUMS \
  --repo InsaneArts/herdrbar --title "Herdrbar 0.1.0" --notes-file NOTES.md
cp release/0.1.0/herdrbar.rb Casks/herdrbar.rb
git commit -am "Herdrbar 0.1.0" && git push
```

The cask and `appcast.xml` point at the release's assets, so publish the release before you push them.
Then `brew install --cask insanearts/herdrbar/herdrbar` installs it, and installed copies find the update
the next time Sparkle checks (once a day, or with Check for Updates… in Settings).
