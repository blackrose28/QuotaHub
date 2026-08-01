pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

import "../code" as Hub

PlasmoidItem {
    id: root

    readonly property bool inPanel: [
        PlasmaCore.Types.TopEdge,
        PlasmaCore.Types.RightEdge,
        PlasmaCore.Types.BottomEdge,
        PlasmaCore.Types.LeftEdge,
    ].includes(Plasmoid.location)

    preferredRepresentation: inPanel ? null : fullRepresentation
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 4

    // --- data reader ---
    Hub.DataReader {
        id: reader
        dataFilePath: Plasmoid.configuration.dataFilePath || ""
        refreshIntervalSec: Plasmoid.configuration.refreshIntervalSec || 900
        warningThreshold: Plasmoid.configuration.warningThreshold || 60
        criticalThreshold: Plasmoid.configuration.criticalThreshold || 80
    }

    // --- executable data source for file reading ---
    Plasma5Support.DataSource {
        id: fileExec
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            const stdout = data["stdout"] || "";
            reader.handleCommandOutput(stdout);
            disconnectSource(sourceName);
        }

        function run(cmd) {
            connectSource(cmd);
        }
    }

    // The default data file path.
    // We avoid StandardPaths (not available in Plasma 6 QML) and instead
    // resolve HOME via environment at startup.
    property string _resolvedHome: ""

    function dataFilePath() {
        const custom = (Plasmoid.configuration.dataFilePath || "").trim();
        if (custom.length > 0) {
            return custom;
        }
        if (_resolvedHome.length > 0) {
            return _resolvedHome + "/.local/share/quotahub/status.json";
        }
        // Fallback — will be updated by homeResolver on first run
        return "/tmp/quotahub-status.json";
    }

    // Resolve $HOME at startup
    Plasma5Support.DataSource {
        id: homeResolver
        engine: "executable"
        connectedSources: ["echo $HOME"]
        onNewData: function(sourceName, data) {
            const home = (data["stdout"] || "").trim();
            if (home.length > 0) {
                root._resolvedHome = home;
                // Now that we have the home path, do the initial refresh
                root.refresh();
            }
            disconnectSource(sourceName);
        }
    }

    function refresh() {
        if (_resolvedHome.length === 0 && (Plasmoid.configuration.dataFilePath || "").trim().length === 0) {
            return; // Wait for homeResolver
        }
        const path = dataFilePath();
        fileExec.run("cat '" + path + "' 2>/dev/null");
    }

    // Trigger the collector service on-demand, then read the fresh data.
    // Gated by a 60-second cooldown to avoid spamming the collector.
    property real _lastCollectTime: 0

    function collectAndRefresh() {
        const now = Date.now();
        if (now - _lastCollectTime < 60000) {
            // Still in cooldown — just re-read the existing data
            refresh();
            return;
        }
        _lastCollectTime = now;
        fileExec.run("systemctl --user start quotahub-collector.service");
        delayedRefresh.restart();
    }

    // One-shot timer: read status.json shortly after the collector finishes
    Timer {
        id: delayedRefresh
        interval: 3000
        repeat: false
        onTriggered: root.refresh()
    }

    // --- periodic refresh ---
    Timer {
        id: refreshTimer
        interval: Math.max(Plasmoid.configuration.refreshIntervalSec || 900, 10) * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // --- countdown update timer (every 30s) ---
    Timer {
        id: countdownTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            // Force UI update by touching updatedAt
            reader._updatedAt = reader._updatedAt;
        }
    }

    // Initial load is triggered by homeResolver.onNewData above

    // --- tooltip ---
    Plasmoid.icon: "speedometer"
    toolTipMainText: {
        if (!reader.hasData) {
            return i18n("QuotaHub — No Data");
        }
        return i18n("QuotaHub — %1 service(s)", reader.serviceCount);
    }
    toolTipSubText: {
        if (!reader.hasData) {
            return i18n("Waiting for quota data…");
        }

        let lines = [];
        for (let i = 0; i < reader.servicesModel.count; i++) {
            const svc = reader.servicesModel.get(i);
            const windows = JSON.parse(svc.windowsData || "[]");
            let detail = svc.serviceName;
            if (windows.length > 0) {
                const w = windows[0];
                detail += ": " + (w.used_pct !== undefined ? Math.round(w.used_pct) + "%" : "?");
            }
            lines.push(detail);
        }
        return lines.join("\n");
    }

    // --- representations ---
    compactRepresentation: CompactRepresentation {
        dataReader: reader
        onToggleExpanded: {
            root.expanded = !root.expanded;
            if (root.expanded) {
                root.collectAndRefresh();
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        collapseMarginsHint: true

        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: fullRep.implicitHeight
        Layout.minimumHeight: fullRep.implicitHeight

        FullRepresentation {
            id: fullRep
            anchors.left: parent.left
            anchors.right: parent.right
            dataReader: reader
            onRefreshClicked: root.collectAndRefresh()
        }
    }
}
