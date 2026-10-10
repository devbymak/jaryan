# Jarian

*Jarian* (جریان, "flow" or "current") is a small, open-source macOS menu bar app that shows network speed. It is a native take on the [Internet Speed Monitor](https://github.com/rishuinfinity/InternetSpeedMonitor) GNOME extension. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

<img src="assets/app-icon.png" width="96" alt="Jarian icon">

## Features

- Upload and download speed in the menu bar, side by side or stacked on two lines, upload or download first, or one combined ⇅ value.
- Today's data usage after “=”, as in the GNOME extension. It restarts at midnight and can be reset by hand.
- Bytes (MB/s) or bits (Mb/s); updates every 1, 2, or 5 seconds.
- Popover with live speeds, a 60-sample graph (hover for exact values), today's usage, and per-interface speeds.
- Measures all physical interfaces (Wi-Fi, Ethernet, USB, iPhone tethering) or just one. VPN tunnels, bridges, loopback, and Apple peer-to-peer links (AWDL, Wi-Fi Aware) are skipped so traffic is not counted twice.
- Reads 64-bit kernel counters (`NET_RT_IFLIST2`), so totals don't wrap at 4 GB.
- Open at login, from Settings.
- No logs and no network access of its own. Only preferences and today's usage total are saved.

## Build and run

Requires macOS 13+ and Xcode Command Line Tools.

```sh
./test.sh
./build.sh
open Jarian.app
```

`Jarian.app/Contents/MacOS/jarian --probe` prints each interface's counters and whether it is counted.

`assets/draw-icon.swift` regenerates `assets/app-icon.png`.

## License

MIT — see [license](license).
