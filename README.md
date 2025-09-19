# Pinger

A minimal macOS menu bar application that monitors network connectivity by sending periodic ICMP pings to a selected host.

## Features

- Menu bar indicator with color status:
  - **Green** – host reachable
  - **Red** – host unreachable
  - **Gray** – monitoring paused
- Configurable host list with quick selection from the menu
- Add or remove hosts dynamically (most recent host appears on top)
- Start/Stop control for monitoring
- Adjustable ping interval (0.5s, 1s, 2s, 5s)
- Anti-flap stabilization (require multiple confirmations before state change)
- Optional notifications on connectivity changes
- Optional console logging
- Option to hide or show Dock icon (runtime switch, requires app relaunch)
- Automatic persistence of configuration to  
  `~/Library/Application Support/Pinger/config.json`
- About dialog with version, author, settings file location, and description

## Requirements

- macOS 26.0 or newer
- Access to system `/sbin/ping` (App Sandbox must be disabled for ICMP)
- Xcode to build from source (tested with Xcode 15+)
- No external dependencies

## Installation

- Download & run Release.

OR 

1. Clone the repository:
   ```bash
   git clone https://github.com/Venomen/Pinger.git
   ```
2. Open `Pinger.xcodeproj` in Xcode.
3. Build and run on macOS.
4. After building, you can archive and distribute the `.app` manually (outside the App Store).

## Configuration

- All settings (hosts, active host, interval, anti-flap, notifications, logs, dock visibility) are automatically saved to:
  ```
  ~/Library/Application Support/Pinger/config.json
  ```
- The file is created on first launch and updated on exit or whenever settings change.

## Limitations

- The application relies on the system `ping` binary. Ensure `/sbin/ping` is available and executable.
- App Sandbox must remain **disabled**, otherwise ICMP packets will be blocked.

## Roadmap / TODO

- Automatic update mechanism (e.g., GitHub release check with Sparkle)
- Optional sound alerts on connectivity changes

## License

MIT License – see [LICENSE](LICENSE) for details.

---

Author: [deregowski.net](https://deregowski.net) © 2025
