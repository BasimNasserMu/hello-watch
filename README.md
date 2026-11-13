# HelloWatch

Minimal iPhone + Apple Watch SwiftUI app, built on GitHub Actions (no Mac needed) into an unsigned IPA for sideloading.

- `Phone/` – iPhone container app
- `Watch/` – watchOS app: one big button — tap to buzz the watch once, press and hold for a continuous buzz (embedded in the IPA under `HelloWatch.app/Watch/`)
- `project.yml` – XcodeGen spec; the Xcode project is generated in CI

Download `HelloWatch.ipa` from the latest workflow run's artifacts and sign/install it with Sideloadly.
