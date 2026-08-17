# QuotaHub

A KDE Plasma 6 widget + systemd collector that monitors your AI subscription quotas in real time.

![KDE Plasma 6](https://img.shields.io/badge/KDE_Plasma-6.0+-blue?logo=kde)
![Python 3.10+](https://img.shields.io/badge/Python-3.10+-yellow?logo=python)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Supported Services

| Service | Plan Detection | Quota Windows |
|---------|---------------|---------------|
| **Claude Code** | Pro, Max 5×/20×, Team, Enterprise | 5 h rolling, weekly |
| **Antigravity** (Gemini + Claude/GPT) | Free, Pro, Ultra | 5 h rolling, weekly |
| **Codex** (OpenAI) | Plus, Pro, Business, Enterprise | 5 h rolling, weekly |
| **Command Code** (`cmd`) | Go, GOAT, Pro, Provider, Max, Ultra, Teams Pro | 5 h rolling, weekly (or monthly credits) |

## How It Works

```
systemd timer (every 30 s)
    └─▶ quotahub-collector.py
            ├─ Claude Code OAuth usage API
            ├─ Antigravity CloudCode internal API
            ├─ Codex ChatGPT backend API
            └─ Command Code commandcode.ai backend API
                    └─▶ ~/.local/share/quotahub/status.json
                            └─▶ KDE Plasma widget reads & displays
```

1. **Collector** — A Python script that queries each service's API and writes a unified `status.json`.
2. **Widget** — A QML plasmoid that reads `status.json` and renders quota cards with color-coded status indicators.

## Installation

```bash
git clone https://github.com/<your-user>/QuotaHub.git
cd QuotaHub
./install.sh          # installs both widget + collector
```

You can also install components individually:

```bash
./install.sh widget      # KDE widget only
./install.sh collector   # collector + systemd timer only
```

After installation, right-click your panel → **Add Widgets** → search **"QuotaHub"**.

### Uninstall

```bash
./install.sh uninstall
```

## Prerequisites

- **KDE Plasma 6.0+**
- **Python 3.10+** (standard library only — no pip packages required)
- **python-dbus** — for reading Antigravity credentials from the system keyring
- Active subscriptions to one or more of the supported services
- For Codex support: the `codex` CLI must be installed and logged in (`~/.codex/auth.json` must exist)
- For Command Code support: the `cmd` CLI must be installed and logged in (`~/.commandcode/auth.json` must exist)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `QUOTAHUB_DATA_DIR` | `~/.local/share/quotahub` | Directory for `status.json` output |
| `QUOTAHUB_LOG_LEVEL` | `INFO` | Logging verbosity (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

## Project Structure

```
QuotaHub/
├── collector/
│   ├── quotahub-collector.py       # Main collector script
│   ├── quotahub-collector.service  # systemd service unit
│   └── quotahub-collector.timer    # systemd timer unit (30 s interval)
├── kde/
│   └── org.quotahub/
│       ├── metadata.json           # KDE widget metadata
│       └── contents/
│           ├── code/
│           │   └── DataReader.qml  # JSON file reader component
│           ├── config/
│           │   ├── config.qml      # Config page definitions
│           │   └── main.xml        # Config schema
│           └── ui/
│               ├── main.qml              # Widget entry point
│               ├── CompactRepresentation.qml  # Panel icon
│               ├── FullRepresentation.qml     # Expanded popup
│               ├── QuotaCard.qml              # Per-service card
│               └── ConfigGeneral.qml          # Settings page
├── install.sh                      # Installer / uninstaller
├── LICENSE
└── README.md
```

## License

[MIT](LICENSE)
