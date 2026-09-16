pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

/**
 * CompactRepresentation — sits in the KDE panel.
 *
 * Shows a grid of colored dots:
 *   - Each column = one service
 *   - Stacked dots = usage window statuses (5h rolling, weekly, 30d, etc.)
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

    readonly property real dotSize: Kirigami.Units.gridUnit * 0.45

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

    // Helper: get status color for a window's used_pct, or service fallback
    function _dotColor(win, fallbackStatus) {
        if (!dataReader) return "#94a3b8";
        if (!win || win.used_pct === undefined || win.used_pct === null) {
            return dataReader.statusColor(fallbackStatus || "unknown");
        }
        var s = dataReader.statusForPct(
            win.used_pct, dataReader.warningThreshold, dataReader.criticalThreshold
        );
        return dataReader.statusColor(s);
    }

    function _dotIsCritical(win) {
        if (!dataReader || !win || win.used_pct === undefined || win.used_pct === null) {
            return false;
        }
        var s = dataReader.statusForPct(
            win.used_pct, dataReader.warningThreshold, dataReader.criticalThreshold
        );
        return s === "critical" || s === "exhausted";
    }

    RowLayout {
        id: dotGrid
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        // Fallback: single grey dot when no data
        Rectangle {
            visible: !compactRoot.dataReader || !compactRoot.dataReader.hasData
            width: compactRoot.dotSize
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

        // One column per service, dots stacked per active window
        Repeater {
            model: compactRoot.dataReader ? compactRoot.dataReader.servicesModel : null

            ColumnLayout {
                id: serviceCol
                required property int index
                required property string status
                required property string windowsData

                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                readonly property var parsedWindows: {
                    try {
                        var arr = JSON.parse(windowsData || "[]");
                        return Array.isArray(arr) && arr.length > 0 ? arr : [null];
                    } catch (e) {
                        return [null];
                    }
                }

                Repeater {
                    model: serviceCol.parsedWindows

                    Rectangle {
                        id: dotRect
                        required property int index
                        required property var modelData

                        readonly property bool isCritical: compactRoot._dotIsCritical(modelData)

                        width: compactRoot.dotSize
                        height: width
                        radius: width / 2
                        color: compactRoot._dotColor(modelData, serviceCol.status)

                        Behavior on color { ColorAnimation { duration: 300 } }

                        // Glow for critical states
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * 1.5
                            height: width
                            radius: width / 2
                            color: parent.color
                            visible: dotRect.isCritical
                            opacity: glowAnim.running ? glowAnim.currentOpacity : 0
                            z: -1

                            SequentialAnimation {
                                id: glowAnim
                                loops: Animation.Infinite
                                running: dotRect.isCritical
                                property real currentOpacity: 0

                                NumberAnimation {
                                    target: glowAnim; property: "currentOpacity"
                                    to: 0.4; duration: 600; easing.type: Easing.InOutQuad
                                }
                                NumberAnimation {
                                    target: glowAnim; property: "currentOpacity"
                                    to: 0.0; duration: 600; easing.type: Easing.InOutQuad
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
