# Releasing Herdrbar

`Scripts/release.sh` builds a release on your Mac. It publishes nothing and changes no files in Git.

## Build

1. Set `MARKETING_VERSION` and a higher `BUILD_NUMBER` in `version.env`, then commit.
2. Run `Scripts/release.sh`.

It needs a clean checkout, the Developer ID certificate in the login Keychain, and the `AC_PASSWORD`
notarytool profile. Set `APP_IDENTITY`, `TEAM_ID`, or `NOTARY_PROFILE` when yours differ.

The script runs the tests, builds for Apple silicon and Intel, signs with the hardened runtime, notarizes,
staples, and checks the app with Gatekeeper. `release/VERSION/` then holds:

- `Herdrbar-VERSION.zip`: the notarized app.
- `herdrbar.rb`: the Homebrew cask, with the zip's SHA-256.
- `SHA256SUMS`: checksums for both.

## Publish

```sh
gh release create v0.1.0 release/0.1.0/Herdrbar-0.1.0.zip release/0.1.0/SHA256SUMS \
  --repo InsaneArts/herdrbar --title "Herdrbar 0.1.0" --notes-file NOTES.md
cp release/0.1.0/herdrbar.rb Casks/herdrbar.rb
git commit -am "Herdrbar 0.1.0 cask" && git push
```

The cask points at the release asset, so publish the release before you push the cask. Then
`brew install --cask insanearts/herdrbar/herdrbar` installs it.
