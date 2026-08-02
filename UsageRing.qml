import QtQuick
import qs.Common

Item {
    id: root

    property int percentage: 0
    property color ringColor: Theme.primary
    property int diameter: 16
    property real thickness: 2.5
    property bool available: true
    property string accessibleName: "Usage"
    readonly property real fraction: available ? Math.max(0, Math.min(1, percentage / 100)) : 0

    implicitWidth: diameter
    implicitHeight: diameter
    Accessible.name: accessibleName
    Accessible.role: Accessible.Indicator

    Canvas {
        id: canvas
        anchors.fill: parent

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()

            const center = Math.min(width, height) / 2
            const radius = Math.max(0, (Math.min(width, height) - root.thickness) / 2)
            ctx.lineWidth = root.thickness
            ctx.strokeStyle = Theme.surfaceVariant
            ctx.beginPath()
            ctx.arc(center, center, radius, 0, 2 * Math.PI)
            ctx.stroke()

            if (root.fraction > 0) {
                ctx.strokeStyle = root.ringColor
                ctx.lineCap = "round"
                ctx.beginPath()
                ctx.arc(center, center, radius, -Math.PI / 2,
                        -Math.PI / 2 + root.fraction * 2 * Math.PI)
                ctx.stroke()
            }
        }

        Connections {
            target: root
            function onPercentageChanged() { canvas.requestPaint() }
            function onRingColorChanged() { canvas.requestPaint() }
            function onAvailableChanged() { canvas.requestPaint() }
        }
    }
}
