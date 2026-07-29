pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

/**
 * CompactRepresentation — sits in the KDE panel.
 *
 * Shows a 3×2 grid of colored dots:
 *   - Each column = one service
 *   - Top row = 5h rolling window status
 *   - Bottom row = weekly window status
 *
 * Colors:
 *   green (#4ade80) = ok
 *   yellow (#facc15) = warning
 *   red (#f87171) = critical / exhausted
 *   purple (#a855f7) = error
 *   grey (#94a3b8) = unknown / no data
 */
MouseArea {
    id: compactRoot

    property var dataReader: null
    signal toggleExpanded()

    Layout.minimumWidth: dotGrid.implicitWidth + Kirigami.Units.smallSpacing * 2
    Layout.minimumHeight: dotGrid.implicitHeight + Kirigami.Units.smallSpacing
    Layout.preferredWidth: dotGrid.implicitWidth + Kirigami.Units.smallSpacing * 2
    Layout.preferredHeight: dotGrid.implicitHeight + Kirigami.Units.smallSpacing

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton

    onClicked: {
        console.log("[QuotaHub] CLICK registered, emitting toggleExpanded");
        compactRoot.toggleExpanded();
    }

    // Helper: get per-window status color from a service's windowsData
    function _windowColor(windowsData, windowIndex) {
        if (!dataReader) return "#94a3b8";
        try {
            var windows = JSON.parse(windowsData || "[]");
            if (windowIndex >= windows.length) return "#94a3b8";
            var pct = windows[windowIndex].used_pct;
            if (pct === undefined || pct === null) return "#94a3b8";
            var s = dataReader.statusForPct(
                pct, dataReader.warningThreshold, dataReader.criticalThreshold
            );
            return dataReader.statusColor(s);
        } catch (e) {
            return "#94a3b8";
        }
    }

    function _windowIsCritical(windowsData, windowIndex) {
        if (!dataReader) return false;
        try {
            var windows = JSON.parse(windowsData || "[]");
            if (windowIndex >= windows.length) return false;
            var pct = windows[windowIndex].used_pct;
            if (pct === undefined || pct === null) return false;
            var s = dataReader.statusForPct(
                pct, dataReader.warningThreshold, dataReader.criticalThreshold
            );
            return s === "critical" || s === "exhausted";
        } catch (e) {
            return false;
        }
    }

    Row {
        id: dotGrid
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        // Fallback: single grey dot when no data
        Rectangle {
            visible: !compactRoot.dataReader || !compactRoot.dataReader.hasData
            width: Kirigami.Units.gridUnit * 0.6
            height: width
            radius: width / 2
            color: "#94a3b8"
            opacity: pulseAnim.running ? pulseAnim.currentOpacity : 1.0

            SequentialAnimation {
                id: pulseAnim
                loops: Animation.Infinite
                running: !compactRoot.dataReader || !compactRoot.dataReader.hasData

                property real currentOpacity: 1.0

                NumberAnimation {
                    target: pulseAnim; property: "currentOpacity"
                    to: 0.3; duration: 800; easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: pulseAnim; property: "currentOpacity"
                    to: 1.0; duration: 800; easing.type: Easing.InOutQuad
                }
            }
        }

        // One column per service, two dots stacked (5h on top, weekly on bottom)
        Repeater {
            model: compactRoot.dataReader ? compactRoot.dataReader.servicesModel : null

            Column {
                required property int index
                required property string windowsData

                spacing: 2

                // Top dot: 5h rolling (window index 0)
                Rectangle {
                    width: Kirigami.Units.gridUnit * 0.55
                    height: width
                    radius: width / 2
                    color: compactRoot._windowColor(windowsData, 0)

                    Behavior on color { ColorAnimation { duration: 300 } }

                    // Glow for critical states
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 1.5
                        height: width
                        radius: width / 2
                        color: parent.color
                        visible: compactRoot._windowIsCritical(windowsData, 0)
                        opacity: glow5h.running ? glow5h.currentOpacity : 0
                        z: -1

                        SequentialAnimation {
                            id: glow5h
                            loops: Animation.Infinite
                            running: compactRoot._windowIsCritical(windowsData, 0)
                            property real currentOpacity: 0

                            NumberAnimation {
                                target: glow5h; property: "currentOpacity"
                                to: 0.4; duration: 600; easing.type: Easing.InOutQuad
                            }
                            NumberAnimation {
                                target: glow5h; property: "currentOpacity"
                                to: 0.0; duration: 600; easing.type: Easing.InOutQuad
                            }
                        }
                    }
                }

                // Bottom dot: weekly (window index 1)
                Rectangle {
                    width: Kirigami.Units.gridUnit * 0.55
                    height: width
                    radius: width / 2
                    color: compactRoot._windowColor(windowsData, 1)

                    Behavior on color { ColorAnimation { duration: 300 } }

                    // Glow for critical states
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 1.5
                        height: width
                        radius: width / 2
                        color: parent.color
                        visible: compactRoot._windowIsCritical(windowsData, 1)
                        opacity: glowWeekly.running ? glowWeekly.currentOpacity : 0
                        z: -1

                        SequentialAnimation {
                            id: glowWeekly
                            loops: Animation.Infinite
                            running: compactRoot._windowIsCritical(windowsData, 1)
                            property real currentOpacity: 0

                            NumberAnimation {
                                target: glowWeekly; property: "currentOpacity"
                                to: 0.4; duration: 600; easing.type: Easing.InOutQuad
                            }
                            NumberAnimation {
                                target: glowWeekly; property: "currentOpacity"
                                to: 0.0; duration: 600; easing.type: Easing.InOutQuad
                            }
                        }
                    }
                }
            }
        }
    }
}
