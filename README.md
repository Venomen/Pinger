# Pinger

A minimal macOS menu bar application that monitors network connectivity by sending periodic ICMP pings or HTTP requests to selected hosts.

## Features

- **Dual Protocol Monitoring**: Support for both ICMP ping and HTTP monitoring
  - **ICMP Mode**: Traditional network ping using system `/sbin/ping`
  - **HTTP Mode**: HTTP HEAD requests with redirect handling and SSL validation
- **Per-Host Protocol Selection**: Toggle between ICMP and HTTP monitoring for each host individually
- Menu bar indicator with color status:
  - **Green** – host reachable
  - **Red** – host unreachable
  - **Gray** – monitoring paused
- Configurable host list with quick selection from the menu
- Add or remove hosts dynamically (most recent host appears on top)
- **Monitoring Type Toggle**: Click the protocol icon (EKG for ICMP, Globe for HTTP) next to each host to switch between monitoring types
- Start/Stop control for monitoring
- Adjustable ping interval (0.5s, 1s, 2s, 5s) - applies to both ICMP and HTTP monitoring
- Anti-flap stabilization (require multiple confirmations before state change)
- Optional notifications on connectivity changes
- Optional console logging
- Option to hide or show Dock icon (runtime switch, requires app relaunch)
- **HTTP Features**:
  - Automatic redirect following (301, 302, 303, 307, 308)
  - SSL certificate validation
  - Configurable timeout (5 seconds)
  - HTTP status code tracking and display in tooltips
- Automatic persistence of configuration to  
  `~/Library/Application Support/Pinger/config.json`
- About dialog with version, author, settings file location, and description

## Requirements

- macOS 26.0 or newer
- **For ICMP monitoring**: Access to system `/sbin/ping` (App Sandbox must be disabled)
- **For HTTP monitoring**: Standard network access (works with App Sandbox enabled)
- Xcode to build from source (tested with Xcode 15+)
- No external dependencies

## Installation

1. Download & run Release.
2. On first launch, macOS will warn because the app is from an unidentified developer. Use right-click → Open to run it.

OR 

1. Clone the repository:
   ```bash
   git clone https://github.com/Venomen/Pinger.git
   ```
2. Open `Pinger.xcodeproj` in Xcode.
3. Build and run on macOS.
4. After building, you can archive and distribute the `.app` manually (outside the App Store).

## Usage

### Basic Operation
1. Launch Pinger - it appears in the menu bar
2. Click the menu bar icon to open the menu
3. Add hosts using the text field at the bottom
4. Select a host to monitor from the list

### Monitoring Type Selection
- Each host has a protocol icon next to it:
  - **EKG/Heartbeat icon** (📈) = ICMP ping monitoring
  - **Globe icon** (🌐) = HTTP monitoring
- **Click the icon** to toggle between ICMP and HTTP monitoring for that specific host
- The application remembers the monitoring type for each host

### Host Configuration
- **ICMP hosts**: Use IP addresses or hostnames (e.g., `8.8.8.8`, `google.com`)
- **HTTP hosts**: Use full URLs (e.g., `https://google.com`, `http://example.com`)
- **Mixed monitoring**: You can have some hosts using ICMP and others using HTTP simultaneously

## Configuration

- All settings (hosts, active host, interval, anti-flap, notifications, logs, dock visibility, **monitoring types per host**) are automatically saved to:
  ```
  ~/Library/Application Support/Pinger/config.json
  ```
- The file is created on first launch and updated on exit or whenever settings change.

## Limitations

- **ICMP monitoring**: Relies on the system `ping` binary. Ensure `/sbin/ping` is available and executable.
- **ICMP monitoring**: App Sandbox must remain **disabled**, otherwise ICMP packets will be blocked.
- **HTTP monitoring**: Works with standard network permissions and App Sandbox enabled.
- **Mixed monitoring**: If using both ICMP and HTTP hosts, App Sandbox must be disabled due to ICMP requirements.

## Known Issues

- Copy/Paste from Clipboard to Host field - sometime works ;-)

## Roadmap / TODO

- Automatic update mechanism (e.g., GitHub release check with Sparkle)
- Optional sound alerts on connectivity changes
- Advanced HTTP monitoring options (custom headers, authentication)
- Performance metrics and response time tracking

## License

MIT License – see [LICENSE](LICENSE) for details.

---

Author: [deregowski.net](https://deregowski.net) © 2025
