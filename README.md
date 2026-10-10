# Pressure

Pressure is a menu-bar app that watches macOS memory and quits the background apps you marked as expendable before the system runs out of memory.

The pressure score is `100 − kern.memorystatus_level`: the kernel’s own “percent of memory still available,” inverted so higher means worse. It is not the “Memory Used” number in Activity Monitor, which stays high on a healthy Mac.

## What it does

- A Hub sits on the left edge, vertically centered. It stays a compact black pill, then morphs open when the pointer reaches the middle of that edge. The expanded card has the same controls as a Dynamic Island: live pressure, and switches for auto-close, warnings, quit notifications, and launch at login.
- Polls memory every 2 seconds and shows a green, yellow, or red gauge plus the current percentage.
- Warns at 70, turns red at 85, and starts auto-close at 90. All three are adjustable, and they stay in that order.
- Auto-close only quits apps you add to the close list, from the bottom of the list upward.
- It skips the app you are using, Pressure itself, and session processes (Finder, Dock, Control Center, and the other menu-bar agents).
- Quit is graceful first. If the app is still running after 5 seconds, Pressure force quits it.
- Closing pauses after 5 apps in one spike, then waits until pressure falls below the critical threshold.
- The menu can close the largest app (after a confirmation) or run `purge`, which asks for an administrator password once.
- Settings include the close list, an extra protected list, notifications, and launch at login.

## Download

The disk image is hosted on GitHub Pages:

[Download Pressure.dmg](https://bdawgsawesome1-mainlinestudiosofficial.github.io/Pressure/)

Open the image, drag Pressure into Applications, then open it. If macOS says the developer can’t be verified, right-click Pressure and choose Open. This build is ad-hoc signed and not notarized.

## Build

Xcode is optional. From the repo root:

```bash
scripts/build.sh
open build/Pressure.app
```

The script compiles with the Swift command-line tools, signs the app ad hoc, and runs the decision-logic tests. Opening `Pressure.xcodeproj` works once Xcode is installed. The deployment target is macOS 13.

Launch at login uses `SMAppService` and needs a stably signed copy, ideally in `/Applications`. An ad-hoc build will explain that in Settings if macOS rejects it.

## Safety

Pressure never auto-closes an app that is not on your list. The first time it quits an app, macOS may ask permission to control that app. `purge` is manual and is the only step that needs an administrator password.
