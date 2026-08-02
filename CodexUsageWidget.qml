// Codex usage limits as a compact DMS bar pill and a two-window popout.
import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import DankCodexUsage 1.0

PluginComponent {
    id: root
    pluginId: "codexUsage"

    readonly property int warnPct: 70
    readonly property int critPct: 90
    readonly property int staleMinutes: 60
    readonly property bool hasData: CodexUsageData.hasData

    function color(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    function limits() {
        return [
            { key: "primary", value: CodexUsageData.primary },
            { key: "secondary", value: CodexUsageData.secondary }
        ]
    }

    function label(limit) {
        if (limit.value !== null)
            return CodexUsageData.windowLabel(limit.value.window_minutes)
        return limit.key === "primary" ? "Primary" : "Secondary"
    }

    function percentage(limit) {
        return limit.value === null ? "--" : limit.value.used_percentage + "%"
    }

    function accessibleLimitName(limit) {
        return limit.value === null
            ? root.label(limit) + ", usage unavailable"
            : root.label(limit) + ", " + root.percentage(limit) + " used"
    }

    function resetText(limit) {
        if (limit.value === null)
            return "Usage unavailable"
        if (limit.value.resetting)
            return "Resetting…"
        return "resets in " + CodexUsageData.countdown(limit.value.resets_at)
    }

    function errorText() {
        switch (CodexUsageData.errorCategory) {
        case "codex_missing": return "Codex CLI is not installed."
        case "dependency_missing": return "A required local dependency is missing."
        case "chatgpt_sign_in_required": return "Sign in to Codex with ChatGPT."
        case "api_key_unsupported": return "API-key sessions do not expose ChatGPT limits."
        case "rate_limits_unavailable": return "Codex rate limits are unavailable."
        case "codex_version_unsupported": return "Update Codex CLI to version 0.133.0 or newer."
        case "timeout": return "Codex usage refresh timed out."
        case "refresh_failed": return "Codex usage refresh failed."
        default: return ""
        }
    }

    horizontalBarPill: Component {
        StyledRect {
            id: pill
            implicitWidth: row.implicitWidth + Theme.spacingM * 2
            height: root.widgetThickness
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: row
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.hasData
                    text: "✳ --"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.hasData ? root.limits().filter(limit => limit.value !== null) : []
                    delegate: Row {
                        spacing: Theme.spacingXS
                        UsageRing {
                            percentage: modelData.value.used_percentage
                            ringColor: root.color(modelData.value.used_percentage)
                            diameter: Math.max(12, Math.min(root.widgetThickness - Theme.spacingM * 2, 18))
                            accessibleName: root.accessibleLimitName(modelData)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: root.percentage(modelData)
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            id: pill
            width: root.widgetThickness
            implicitHeight: column.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: column
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.hasData
                    text: "✳ --"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }

                Repeater {
                    model: root.hasData ? root.limits().filter(limit => limit.value !== null) : []
                    delegate: Column {
                        spacing: Theme.spacingXS
                        UsageRing {
                            percentage: modelData.value.used_percentage
                            ringColor: root.color(modelData.value.used_percentage)
                            diameter: Math.max(12, Math.min(root.widgetThickness - Theme.spacingM * 2, 18))
                            accessibleName: root.accessibleLimitName(modelData)
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: root.percentage(modelData)
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 320
    popoutHeight: 250
    popoutContent: Component {
        PopoutComponent {
            headerText: "Codex Usage"
            showCloseButton: true
            closePopout: function() { root.closePopout() }
            headerActions: Component {
                DankActionButton {
                    buttonSize: 28
                    iconName: "refresh"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    Accessible.name: "Refresh Codex usage"
                    tooltipText: "Refresh Codex usage"
                    enabled: !CodexUsageData.refreshing
                    opacity: enabled ? 1.0 : 0.5
                    onClicked: CodexUsageData.refresh(true)
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Repeater {
                    model: root.limits()
                    delegate: Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        UsageRing {
                            readonly property bool windowAvailable: modelData.value !== null
                            percentage: windowAvailable ? modelData.value.used_percentage : 0
                            ringColor: windowAvailable ? root.color(modelData.value.used_percentage) : Theme.surfaceTextMedium
                            available: windowAvailable
                            diameter: 30
                            thickness: 3.5
                            accessibleName: root.accessibleLimitName(modelData)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.spacingM - 30
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                StyledText {
                                    id: labelText
                                    text: root.label(modelData)
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }
                                Item { width: Math.max(0, parent.width - percent.implicitWidth - labelText.implicitWidth) }
                                StyledText {
                                    id: percent
                                    text: root.percentage(modelData)
                                    color: modelData.value === null ? Theme.surfaceTextMedium : root.color(modelData.value.used_percentage)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }
                            }

                            StyledText {
                                readonly property int tick: CodexUsageData.now
                                text: {
                                    tick
                                    return root.resetText(modelData)
                                }
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }
                }

                StyledText {
                    id: refreshStatus
                    width: parent.width
                    visible: CodexUsageData.refreshing
                    text: root.hasData ? "Refreshing…" : "Loading…"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width
                    visible: root.errorText() !== ""
                    text: root.errorText()
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    readonly property int age: CodexUsageData.minutesOld()
                    readonly property int tick: CodexUsageData.now
                    width: parent.width
                    visible: age >= 0
                    text: {
                        tick
                        return age <= root.staleMinutes
                            ? "updated " + (age === 0 ? "just now" : age + "m ago")
                            : "stale (" + age + "m)"
                    }
                    color: age > root.staleMinutes ? Theme.warning : Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
