pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras

/**
 * FullRepresentation — the expanded popup showing all service quota cards.
 */
Item {
    id: fullRoot

    property var dataReader: null
    signal refreshClicked()

    implicitWidth: Kirigami.Units.gridUnit * 20
    implicitHeight: mainLayout.implicitHeight

    ColumnLayout {
        id: mainLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Kirigami.Units.smallSpacing

        // --- header ---
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                source: "speedometer"
            }

            PlasmaExtras.Heading {
                Layout.fillWidth: true
                level: 4
                text: i18n("QuotaHub")
            }

            PlasmaComponents3.Label {
                visible: fullRoot.dataReader && fullRoot.dataReader.updatedAt.length > 0
                text: fullRoot.dataReader ? fullRoot.dataReader.relativeTimeText(fullRoot.dataReader.updatedAt) : ""
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.5
            }

            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh"
                display: PlasmaComponents3.AbstractButton.IconOnly
                PlasmaComponents3.ToolTip.text: i18n("Refresh")
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: fullRoot.refreshClicked()
            }
        }

        // --- separator ---
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Qt.rgba(
                Kirigami.Theme.textColor.r,
                Kirigami.Theme.textColor.g,
                Kirigami.Theme.textColor.b,
                0.1
            )
        }

        // --- empty state ---
        PlasmaComponents3.Label {
            visible: !fullRoot.dataReader || !fullRoot.dataReader.hasData
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
            horizontalAlignment: Text.AlignHCenter
            text: i18n("No quota data available")
            opacity: 0.5
        }

        // --- service cards ---
        ColumnLayout {
            Layout.fillWidth: true
            visible: fullRoot.dataReader && fullRoot.dataReader.hasData
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: fullRoot.dataReader ? fullRoot.dataReader.servicesModel : null

                QuotaCard {
                    required property int index

                    Layout.fillWidth: true
                    dataReader: fullRoot.dataReader
                }
            }
        }
    }
}
