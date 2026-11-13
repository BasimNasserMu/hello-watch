# HelloWatch

Minimal iPhone + Apple Watch SwiftUI app, built on GitHub Actions (no Mac needed) into an unsigned IPA for sideloading.

- `Phone/` – iPhone container app
- `Watch/` – watchOS app: one big button — tap to buzz the watch once, press and hold for a continuous buzz (embedded in the IPA under `HelloWatch.app/Watch/`)
- `project.yml` – XcodeGen spec; the Xcode project is generated in CI

Download `HelloWatch.ipa` from the latest workflow run's artifacts and sign/install it with Sideloadly.

Installing directly on the watch: send the watch app, not the iPhone app. `tools/watchlink.py install HelloWatch.ipa` now pulls the embedded watch app out of a combined IPA automatically, and CI also produces `HelloWatchApp-watch.ipa` (watch app only). Sending the combined IPA's top-level app to the watch fails with `DeviceFamilyNotSupported` (family 1 = iPhone, 4 = watch).
