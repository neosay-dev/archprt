# ArchPrt

Arch Linux ARM on iPhone and iPad: a light Arch in a QEMU virtual machine with a native iOS shell around it.
Needs JIT (StikDebug). Built for iPhone 11 and newer.

- `ios/` — the app (SwiftUI, SwiftTerm terminal with Esc/Ctrl/Tab/arrows/F-key bar, QEMU launcher).
- `guest/` — builds the Arch guest (`build.sh` on aarch64 Linux) and boot-tests it (`smoke.py`).
- CI (`.github/workflows/ios.yml`): the guest is built and boot-tested on an ARM runner and published to the `guest` release (the app downloads it); the unsigned IPA is built on macOS.

QEMU and its libraries come prebuilt from [UTM](https://github.com/utmapp/UTM) (QEMU: GPL-2.0, UTM: Apache-2.0).
Arch Linux ARM: https://archlinuxarm.org. ArchPrt is not affiliated with Arch Linux.
