# Jarian

*Jarian* (جریان, "flow" or "current") is a small, open-source macOS menu bar app that shows network speed. It is a native take on the [Internet Speed Monitor](https://github.com/rishuinfinity/InternetSpeedMonitor) GNOME extension. Built with Swift, SwiftUI, and AppKit, with no third-party dependencies.

<img src="assets/app-icon.png" width="96" alt="Jarian icon">

## Features

- Upload and download speed in the menu bar, stacked on two lines or side by side, upload or download first, or one combined ⇅ value.
- Today's data usage after “=”, as in the GNOME extension. It restarts at midnight and can be reset by hand.
- Totals for yesterday and the last 7, 30, or 90 days, from daily totals kept for as many days as you choose.
- Bytes (MB/s) or bits (Mb/s); updates every 1, 2, or 5 seconds.
- Popover with live speeds, a 60-sample graph with speed and time axes (hover for exact values), today's usage, and per-interface speeds.
- Measures all physical interfaces (Wi-Fi, Ethernet, USB, iPhone tethering) or just one. VPN tunnels, bridges, loopback, Apple peer-to-peer links (AWDL, Wi-Fi Aware), and virtual machine networks (Apple Virtualization, VMware, Parallels, VirtualBox) are skipped so traffic is not counted twice. A virtual machine's internet traffic still counts, on the physical link it goes out through.
- Reads 64-bit kernel counters (`NET_RT_IFLIST2`), so totals don't wrap at 4 GB.
- Optional ping and location, like the “real delay” in VPN clients such as Happ. Every 1 to 60 seconds (5 by default) Jarian times an HTTPS request to Cloudflare, Google, or Apple. The location comes from Cloudflare (country only), ipinfo.io, GeoJS, IP.SB, or ifconfig.co, or it can be turned off. All of them are free and need no account. Requests take the same route as your other traffic, through any VPN or proxy. The popover shows the ping, the country flag, the city, the IP address, and the network operator websites see. Below them, a 10-minute ping graph marks lost pings in red. Hover over it to see each ping. Like the speed graph, it lives in memory only. The menu bar can also show the flag and country code, with the ping below them. Like fan speed in Baadgir, the ping is colored by how fast it is: yellow from 150 ms, red from 400 ms or when there is no reply. This can be turned off in Settings. The ping is one network round trip: the time from sending the request to the first byte of the reply. Connection setup isn't counted. When the network drops, a ping goes unanswered, or the route changes, the old ping and location are cleared rather than left on screen. Ping can be switched on and off in Settings or from the right-click menu.
- Launch at login, from Settings.
- Runs in the App Sandbox with Hardened Runtime, allowed only outgoing network connections: it cannot read your files or accept connections. Replies from ping and location services are capped at 64 KB and cleaned before display. Requests carry no cookies, a generic user agent, and no language preferences, so they say nothing about the app, your Mac, or you beyond the IP address any server sees.
- No logs. With ping off (the default), Jarian has no network access of its own. With it on, Jarian contacts only the ping server and location service you choose. The speed graph lives in memory only. On disk there are only preferences and one total per day for the days you keep (at most 90), so saved data never grows over time.

## Build and run

Requires macOS 13+ and Xcode Command Line Tools.

```sh
./test.sh
./build.sh --install   # builds, replaces /Applications/Jarian.app, and opens it
```

`./build.sh` alone builds `Jarian.app` here without installing it. Only one copy runs at a time; a second launch quits immediately.

`Jarian.app/Contents/MacOS/jarian --probe` prints each interface's counters and whether it is counted. `--ping` prints ping and location readings for 30 seconds, using the providers chosen in Settings. Override them with `-pingServer google|apple|cloudflare`, `-locationService ipinfo|geojs|ipsb|ifconfig|cloudflare|off`, and `-pingInterval 1|2|5|10|30|60` before `--ping`.

The build is signed ad-hoc, so it runs on the Mac that built it; Gatekeeper blocks it elsewhere. To share it, sign with a Developer ID and notarize:

```sh
JARIAN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./build.sh
ditto -c -k --keepParent Jarian.app Jarian.zip
xcrun notarytool submit Jarian.zip --keychain-profile <profile> --wait
xcrun stapler staple Jarian.app
```

Because of the sandbox, preferences live in `~/Library/Containers/local.jarian`. The first sandboxed launch moves them there from `~/Library/Preferences`, so builds from before the sandbox will start with default settings.

`assets/app-icon.png` is the app icon; `assets/icon-prompt.txt` records its image-generation prompt.

## License

MIT — see [license](license).
