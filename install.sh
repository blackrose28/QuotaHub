#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_WIDGET="${SCRIPT_DIR}/kde/org.quotahub"
COLLECTOR_DIR="${SCRIPT_DIR}/collector"

PLASMOIDS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids"
WIDGET_ID="org.quotahub"
WIDGET_TARGET="${PLASMOIDS_DIR}/${WIDGET_ID}"

QUOTAHUB_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/quotahub"
COLLECTOR_TARGET="${QUOTAHUB_DATA_DIR}/quotahub-collector.py"

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

usage() {
  cat <<EOF
Usage: $(basename "$0") [widget|collector|all]

  widget     Install the KDE Plasma widget only
  collector  Install the collector script + systemd timer
  all        Install both (default)

  uninstall  Remove widget, collector, and systemd units
EOF
}

install_widget() {
  echo "Installing QuotaHub widget…"

  if [[ ! -d "${SOURCE_WIDGET}" ]]; then
    echo "Error: Widget source not found at ${SOURCE_WIDGET}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${WIDGET_TARGET}")"
  rm -rf "${WIDGET_TARGET}"
  cp -R "${SOURCE_WIDGET}/." "${WIDGET_TARGET}/"

  echo "  Widget installed to: ${WIDGET_TARGET}"
}

install_collector() {
  echo "Installing QuotaHub collector…"

  # Copy collector script
  mkdir -p "${QUOTAHUB_DATA_DIR}"
  cp "${COLLECTOR_DIR}/quotahub-collector.py" "${COLLECTOR_TARGET}"
  chmod +x "${COLLECTOR_TARGET}"
  echo "  Collector script: ${COLLECTOR_TARGET}"

  # Install systemd units
  mkdir -p "${SYSTEMD_USER_DIR}"
  cp "${COLLECTOR_DIR}/quotahub-collector.service" "${SYSTEMD_USER_DIR}/"
  cp "${COLLECTOR_DIR}/quotahub-collector.timer" "${SYSTEMD_USER_DIR}/"

  # Patch the service to point to the installed collector
  sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 ${COLLECTOR_TARGET}|" \
    "${SYSTEMD_USER_DIR}/quotahub-collector.service"

  echo "  Systemd units installed to: ${SYSTEMD_USER_DIR}"

  # Enable and start the timer
  systemctl --user daemon-reload
  systemctl --user enable --now quotahub-collector.timer

  echo "  Timer enabled and started"
  echo "  Run manually: python3 ${COLLECTOR_TARGET}"

  # Run the collector once now
  echo "  Running initial collection…"
  python3 "${COLLECTOR_TARGET}" 2>&1 | sed 's/^/    /'
}

uninstall() {
  echo "Uninstalling QuotaHub…"

  # Stop and disable systemd timer
  systemctl --user disable --now quotahub-collector.timer 2>/dev/null || true
  rm -f "${SYSTEMD_USER_DIR}/quotahub-collector.service"
  rm -f "${SYSTEMD_USER_DIR}/quotahub-collector.timer"
  systemctl --user daemon-reload 2>/dev/null || true

  # Remove widget
  rm -rf "${WIDGET_TARGET}"

  # Remove collector (but keep data dir for safety)
  rm -f "${COLLECTOR_TARGET}"

  echo "  Removed widget, collector, and systemd units"
  echo "  Data directory kept: ${QUOTAHUB_DATA_DIR}"
}

refresh_plasma_cache() {
  if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
}

restart_plasmashell() {
  echo "Restarting plasmashell…"
  systemctl --user restart plasma-plasmashell
  echo "  plasmashell restarted"
}

main() {
  local mode="${1:-all}"
  local needs_restart=false

  case "$mode" in
    widget)
      install_widget
      needs_restart=true
      ;;
    collector)
      install_collector
      ;;
    all)
      install_widget
      install_collector
      needs_restart=true
      ;;
    uninstall)
      uninstall
      needs_restart=true
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${mode}" >&2
      usage >&2
      exit 1
      ;;
  esac

  refresh_plasma_cache

  if [[ "$needs_restart" == "true" ]]; then
    restart_plasmashell
  fi

  echo ""
  echo "Done! Add the widget: right-click panel → Add Widgets → search \"QuotaHub\""
}

main "$@"
