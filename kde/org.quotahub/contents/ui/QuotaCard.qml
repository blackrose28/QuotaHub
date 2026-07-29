pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

/**
 * QuotaCard — displays quota usage for a single AI service.
 *
 * Shows:
 *   - Service icon, name, plan badge, status indicator
 *   - Progress bar(s) for each usage window (5h rolling, weekly)
 *   - Countdown timer for reset
 */
Item {
    id: cardRoot

    property var dataReader: null
    required property string serviceId
    required property string serviceName
    required property string plan
    required property string status
    required property string error
    required property string windowsData

    implicitHeight: cardLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
    implicitWidth: parent ? parent.width : 300

    // --- parsed windows ---
    readonly property var windows: {
        try {
            return JSON.parse(windowsData || "[]");
        } catch (e) {
            return [];
        }
    }

    // Helper to safely call dataReader functions
    function _statusColor(s) {
        return dataReader ? dataReader.statusColor(s) : "#94a3b8";
    }

    function _serviceIcon(sid) {
        return dataReader ? dataReader.serviceIcon(sid) : "application-x-executable";
    }

    // --- card background ---
    Rectangle {
        anchors.fill: parent
        radius: Kirigami.Units.cornerRadius
        color: Qt.rgba(
            Kirigami.Theme.backgroundColor.r,
            Kirigami.Theme.backgroundColor.g,
            Kirigami.Theme.backgroundColor.b,
            0.6
        )
        border.width: 1
        border.color: Qt.rgba(
            Kirigami.Theme.textColor.r,
            Kirigami.Theme.textColor.g,
            Kirigami.Theme.textColor.b,
            0.1
        )

        // Left accent strip
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 3
            radius: Kirigami.Units.cornerRadius
            color: cardRoot._statusColor(cardRoot.status)

            Behavior on color {
                ColorAnimation { duration: 300 }
            }
        }
    }

    ColumnLayout {
        id: cardLayout
        anchors {
            fill: parent
            margins: Kirigami.Units.smallSpacing
            leftMargin: Kirigami.Units.smallSpacing + 6  // account for accent strip
        }
        spacing: Kirigami.Units.smallSpacing

        // --- header row: icon + name + plan + status ---
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                source: cardRoot._serviceIcon(cardRoot.serviceId)
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: cardRoot.serviceName
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            // Plan badge
            Rectangle {
                visible: cardRoot.plan.length > 0
                Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                Layout.preferredHeight: planLabel.implicitHeight + 2
                radius: height / 2
                color: Qt.rgba(
                    Kirigami.Theme.highlightColor.r,
                    Kirigami.Theme.highlightColor.g,
                    Kirigami.Theme.highlightColor.b,
                    0.2
                )

                PlasmaComponents3.Label {
                    id: planLabel
                    anchors.centerIn: parent
                    text: cardRoot.plan
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    color: Kirigami.Theme.highlightColor
                }
            }

            // Status dot
            Rectangle {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 0.5
                Layout.preferredHeight: width
                radius: width / 2
                color: cardRoot._statusColor(cardRoot.status)

                Behavior on color {
                    ColorAnimation { duration: 300 }
                }
            }
        }

        // --- error message ---
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: cardRoot.error.length > 0
            text: cardRoot.error
            color: cardRoot._statusColor("error")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            wrapMode: Text.WordWrap
        }

        // --- usage windows ---
        Repeater {
            model: cardRoot.windows.length

            ColumnLayout {
                required property int index

                Layout.fillWidth: true
                spacing: 2

                readonly property var win: cardRoot.windows[index]
                readonly property real pct: win.used_pct !== undefined ? win.used_pct : 0
                readonly property string winStatus: {
                    if (!cardRoot.dataReader) return "unknown";
                    return cardRoot.dataReader.statusForPct(
                        pct,
                        cardRoot.dataReader.warningThreshold,
                        cardRoot.dataReader.criticalThreshold
                    );
                }
                readonly property string countdown: {
                    if (!cardRoot.dataReader) return "";
                    return cardRoot.dataReader.countdownText(win.resets_at);
                }

                // Window label row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: win.name || "Window"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.7
                    }

                    Item { Layout.fillWidth: true }

                    PlasmaComponents3.Label {
                        text: Math.round(pct) + "%"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.weight: Font.DemiBold
                        color: cardRoot._statusColor(winStatus)
                    }

                    PlasmaComponents3.Label {
                        visible: countdown.length > 0
                        text: "⟳ " + countdown
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.6
                    }
                }

                // Progress bar
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 4
                    radius: 2
                    color: Qt.rgba(
                        Kirigami.Theme.textColor.r,
                        Kirigami.Theme.textColor.g,
                        Kirigami.Theme.textColor.b,
                        0.1
                    )

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * Math.min(pct / 100.0, 1.0)
                        radius: 2
                        color: cardRoot._statusColor(winStatus)

                        Behavior on width {
                            NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
                        }

                        Behavior on color {
                            ColorAnimation { duration: 300 }
                        }
                    }
                }
            }
        }
    }
}
