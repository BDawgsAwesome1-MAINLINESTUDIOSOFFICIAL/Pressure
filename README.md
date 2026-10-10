# Pressure

Pressure is a Dynamic Island for Mac. A black pill rests on the left edge of the screen, centered vertically, and springs open when the pointer reaches the middle of that edge. It is Mainline Studios’ side island: the same kind of compact live activities people know from a Dynamic Island, built for the Mac with public APIs. It is not an Apple product, and it is not the iPhone island.

The compact pill stays small. It always shows battery, or AC on a desktop with no battery. When something is playing it adds album art and a play/pause button. A running timer or stopwatch adds its live time. Hover the left-middle hotspot and the pill morphs into the card.

## Live activities

1. Battery is always on the pill: percent, charging or on battery, and a low-battery state. A desktop Mac with no battery shows AC.
2. Now Playing from Music, Spotify, Safari, or Brave, with artwork and play/pause. If nothing is playing, that row hides. Music and Spotify are read with AppleScript. Safari and Brave are read with Apple Events and JavaScript in the browser's own windows; if JavaScript from Apple Events is off, that browser stays quiet and the others still work.
3. A running timer. Presets are 1, 5, 15, and 25 minutes, with start, pause, and cancel. When it finishes, the island opens on its own, then can collapse. The countdown shows on the pill only while it is running.
4. A stopwatch while it is running, with start, stop, lap, and reset. Its time shows on the pill only while it is running.
5. The next calendar event today, on the expanded card. Calendar access is requested the normal way. If access is denied, or today has no event, this row hides.
6. Memory pressure on the expanded card, with one auto-close switch, so the rest of the settings stay in the settings window.

Tapping Now Playing, the battery row, or the event row opens Music, Spotify, Battery settings, or Calendar.

## Memory

Memory is one live activity, not the headline. Auto-close still only quits apps you put on the close list, from the bottom of the list upward. It skips the app you are using, Pressure itself, and session processes such as Finder, Dock, and Control Center. Quit is graceful first, then force quit after 5 seconds. Closing pauses after 5 apps in one spike. Protected apps stay protected. The full sliders and lists live in Settings, not on the island. The island keeps a single auto-close switch.

The pressure score is `100 − kern.memorystatus_level`: the kernel’s own “percent of memory still available,” inverted so higher means worse. It is not the “Memory Used” number in Activity Monitor.

## Download

The disk image is hosted on GitHub Pages:

[Download Pressure.dmg](https://bdawgsawesome1-mainlinestudiosofficial.github.io/Pressure/)

Open the image, drag Pressure into Applications, then open it. If macOS says the developer can’t be verified, right-click Pressure and choose Open. This build is ad-hoc signed and not notarized. Requires macOS 13 or later.

## Build

Xcode is optional. From the repo root:

```bash
scripts/build.sh
open build/Pressure.app
```

The script compiles with the Swift command-line tools, signs the app ad hoc, and runs the decision-logic tests. Opening `Pressure.xcodeproj` works once Xcode is installed. The deployment target is macOS 13. The bundle id stays `com.mainlinestudios.Pressure`.

Launch at login uses `SMAppService` and needs a stably signed copy, ideally in `/Applications`. An ad-hoc build will explain that in Settings if macOS rejects it.

The first Now Playing control asks for permission to control Music, Spotify, Safari, or Brave. The first calendar read asks for calendar access. Both are optional: if you decline, that activity stays hidden. A refused Music or Spotify control shows one line on the island: allow it in Automation.

## Safety

Pressure never auto-closes an app that is not on your list. The first time it quits an app, macOS may ask permission to control that app. `purge` is manual and is the only step that needs an administrator password.

Face ID animations, AirDrop, system phone calls, and live activities pushed in by other apps are not available through public macOS APIs, so the island does not pretend to do them.
