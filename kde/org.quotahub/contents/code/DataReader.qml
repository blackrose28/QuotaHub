pragma ComponentBehavior: Bound

import QtQuick

/**
 * DataReader — reads and parses the QuotaHub status.json file.
 *
 * Hosts the Plasma5Support.DataSource for file reading and exposes parsed
 * service data via a ListModel.  The actual DataSource must be instantiated
 * in a QML file that can import org.kde.plasma.plasma5support (the UI layer),
 * then wired in via the fileReaderSource property.
 */
QtObject {
    id: root

    // --- public configuration ---
    property string dataFilePath: ""
    property int refreshIntervalSec: 900
    property int warningThreshold: 60
    property int criticalThreshold: 80

    // --- public read-only state ---
    readonly property bool hasData: servicesModel.count > 0
    readonly property string updatedAt: _updatedAt
    readonly property string worstStatus: _worstStatus
    readonly property int serviceCount: servicesModel.count

    // ListModel must be created via property — QtObject has no default
    // property to hold child QML objects.
    property ListModel servicesModel: ListModel {}

    // --- private state ---
    property string _updatedAt: ""
    property string _worstStatus: "unknown"
    property bool _loading: false

    // --- severity helpers ---
    function statusSeverity(status) {
        const order = {
            "ok": 0,
            "unknown": 1,
            "warning": 2,
            "critical": 3,
            "exhausted": 4,
            "error": 5,
        };
        return order[status] !== undefined ? order[status] : 1;
    }

    function statusForPct(pct, warn, crit) {
        if (pct === undefined || pct === null) {
            return "unknown";
        }
        if (pct >= 95) {
            return "exhausted";
        }
        if (pct >= crit) {
            return "critical";
        }
        if (pct >= warn) {
            return "warning";
        }
        return "ok";
    }

    function statusColor(status) {
        switch (status) {
            case "ok":        return "#4ade80";
            case "warning":   return "#facc15";
            case "critical":  return "#f87171";
            case "exhausted": return "#ef4444";
            case "error":     return "#a855f7";
            default:          return "#94a3b8";
        }
    }

    function serviceIcon(serviceId) {
        switch (serviceId) {
            case "claude_code":   return "dialog-scripts";
            case "antigravity":   return "applications-science";
            case "agy_gemini":    return "applications-science";
            case "agy_3p":        return "applications-science";
            case "codex":         return "code-context";
            case "opencode":      return "code-class";
            case "commandcode":   return "utilities-terminal";
            default:              return "application-x-executable";
        }
    }

    // --- countdown formatting ---
    function countdownText(isoResetTime) {
        if (!isoResetTime) {
            return "";
        }
        const resetMs = new Date(isoResetTime).getTime();
        if (Number.isNaN(resetMs)) {
            return "";
        }
        const deltaMs = resetMs - Date.now();
        if (deltaMs <= 0) {
            return "resetting…";
        }
        const totalMin = Math.floor(deltaMs / 60000);
        const totalHours = Math.floor(totalMin / 60);
        const minutes = totalMin % 60;
        if (totalHours >= 24) {
            const days = Math.floor(totalHours / 24);
            const hours = totalHours % 24;
            if (hours > 0) {
                return days + "d " + hours + "h";
            }
            return days + "d";
        }
        if (totalHours > 0) {
            return totalHours + "h " + minutes + "m";
        }
        return minutes + "m";
    }

    function relativeTimeText(isoTime) {
        if (!isoTime) {
            return "";
        }
        const ts = new Date(isoTime).getTime();
        if (Number.isNaN(ts)) {
            return isoTime;
        }
        const deltaMs = Date.now() - ts;
        const minutes = Math.floor(deltaMs / 60000);
        if (minutes < 1) {
            return "just now";
        }
        if (minutes < 60) {
            return minutes + " min ago";
        }
        const hours = Math.floor(minutes / 60);
        if (hours < 24) {
            return hours + "h ago";
        }
        return Qt.formatDateTime(new Date(isoTime), "MMM d, h:mm AP");
    }

    // --- file reading via command output ---
    function handleCommandOutput(stdout) {
        _loading = false;

        if (!stdout || stdout.trim().length === 0) {
            _worstStatus = "error";
            return;
        }

        let data;
        try {
            data = JSON.parse(stdout);
        } catch (e) {
            _worstStatus = "error";
            return;
        }

        _updatedAt = data.updated_at || "";

        const services = data.services || [];
        servicesModel.clear();

        let worstSev = 0;

        for (let i = 0; i < services.length; i++) {
            const svc = services[i];
            const windows = svc.windows || [];
            const windowsJson = JSON.stringify(windows);

            // Determine per-service status from its windows
            let svcStatus = svc.status || "unknown";

            servicesModel.append({
                serviceId: svc.id || "",
                serviceName: svc.name || svc.id || "Unknown",
                plan: svc.plan || "",
                status: svcStatus,
                error: svc.error || "",
                windowsData: windowsJson,
            });

            const sev = statusSeverity(svcStatus);
            if (sev > worstSev) {
                worstSev = sev;
                _worstStatus = svcStatus;
            }
        }

        if (services.length === 0) {
            _worstStatus = "unknown";
        }
    }
}
