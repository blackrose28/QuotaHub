pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root

    property alias cfg_dataFilePath: dataFilePath.text
    property alias cfg_refreshIntervalSec: refreshInterval.value
    property alias cfg_warningThreshold: warningThreshold.value
    property alias cfg_criticalThreshold: criticalThreshold.value

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Data Source")
        }

        QQC2.TextField {
            id: dataFilePath
            Kirigami.FormData.label: i18n("Status file path:")
            placeholderText: "~/.local/share/quotahub/status.json"
            Layout.fillWidth: true
        }

        QQC2.Label {
            text: i18n("Leave empty to use the default path. The collector writes quota data to this file.")
            font: Kirigami.Theme.smallFont
            opacity: 0.6
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Refresh")
        }

        QQC2.SpinBox {
            id: refreshInterval
            Kirigami.FormData.label: i18n("Refresh interval (seconds):")
            from: 10
            to: 300
            stepSize: 5
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Thresholds")
        }

        QQC2.SpinBox {
            id: warningThreshold
            Kirigami.FormData.label: i18n("Warning threshold (%):")
            from: 10
            to: 95
            stepSize: 5
        }

        QQC2.SpinBox {
            id: criticalThreshold
            Kirigami.FormData.label: i18n("Critical threshold (%):")
            from: 20
            to: 100
            stepSize: 5
        }
    }
}
