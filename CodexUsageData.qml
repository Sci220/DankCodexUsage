pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Singleton {
    id: root

    property var primary: null
    property var secondary: null
    property int capturedAt: 0
    property string errorCategory: ""
    property string errorDetail: ""
    property bool refreshing: false
    readonly property bool hasData: primary !== null || secondary !== null
    property int now: Math.floor(Date.now() / 1000)

    readonly property int refreshSeconds: 300
    readonly property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/DankCodexUsage"
    readonly property string scriptPath: Qt.resolvedUrl("fetch-usage.sh").toString().replace("file://", "")
    readonly property string cachePath: cacheDir + "/usage.json"
    readonly property string errorPath: cacheDir + "/error.json"
    property var refreshedResetEpochs: ({})
    property bool initialUsageResolved: false

    function isInteger(value) {
        return typeof value === "number" && isFinite(value) && Math.floor(value) === value
    }

    function isWindow(value) {
        return value !== null
            && typeof value === "object"
            && !Array.isArray(value)
            && isInteger(value.used_percentage)
            && value.used_percentage >= 0
            && value.used_percentage <= 100
            && isInteger(value.window_minutes)
            && value.window_minutes > 0
            && isInteger(value.resets_at)
            && value.resets_at > 0
    }

    function normalizedWindow(value) {
        return {
            used_percentage: value.used_percentage,
            window_minutes: value.window_minutes,
            resets_at: value.resets_at,
            resetting: value.resets_at <= now
        }
    }

    function loadUsage(text) {
        try {
            const value = JSON.parse(text)
            if (value.version !== 1 || !isInteger(value.captured_at) || value.captured_at < 0)
                return
            if (value.primary === null && value.secondary === null)
                return
            if ((value.primary !== null && !isWindow(value.primary))
                    || (value.secondary !== null && !isWindow(value.secondary)))
                return

            root.capturedAt = value.captured_at
            root.primary = value.primary === null ? null : normalizedWindow(value.primary)
            root.secondary = value.secondary === null ? null : normalizedWindow(value.secondary)
            if (initialUsageResolved)
                checkWindowResets()
        } catch (error) {
            console.warn("codexUsage: bad usage cache:", error)
        }
    }

    function loadError(text) {
        try {
            const value = JSON.parse(text)
            if (value.version !== 1 || typeof value.category !== "string" || !value.category
                    || !isInteger(value.occurred_at) || value.occurred_at < 0
                    || (value.detail !== undefined && typeof value.detail !== "string"))
                return

            root.errorCategory = value.category
            root.errorDetail = value.detail || ""
        } catch (error) {
            console.warn("codexUsage: bad error cache:", error)
        }
    }

    function countdown(resetEpoch) {
        const remainingMinutes = Math.ceil((resetEpoch - now) / 60)
        if (!isInteger(resetEpoch) || remainingMinutes <= 0)
            return "now"

        const days = Math.floor(remainingMinutes / (24 * 60))
        const hours = Math.floor((remainingMinutes % (24 * 60)) / 60)
        const minutes = remainingMinutes % 60
        if (days > 0)
            return days + "d " + hours + "h"
        if (hours > 0)
            return hours + "h " + minutes + "m"
        return remainingMinutes + "m"
    }

    function windowLabel(minutes) {
        if (minutes === 10080)
            return "Weekly"
        if (!isInteger(minutes) || minutes <= 0)
            return ""
        if (minutes % (24 * 60) === 0)
            return (minutes / (24 * 60)) + " day"
        if (minutes % 60 === 0)
            return (minutes / 60) + " hour"
        return minutes + " minute"
    }

    function minutesOld() {
        return capturedAt > 0 ? Math.max(0, Math.floor((now - capturedAt) / 60)) : -1
    }

    function refresh(force) {
        if (refreshing)
            return
        const wallClock = Math.floor(Date.now() / 1000)
        if (!force && capturedAt > 0 && capturedAt <= wallClock
                && wallClock - capturedAt < refreshSeconds)
            return

        refreshing = true
        Proc.runCommand("codexUsage.fetch", ["sh", scriptPath], function(stdout, exitCode) {
            root.refreshing = false
            cacheFile.reload()
            errorFile.reload()
        }, 35, 35000)
    }

    function finishInitialUsageLoad() {
        if (initialUsageResolved)
            return
        initialUsageResolved = true
        refresh(false)
        checkWindowResets()
    }

    function checkWindowReset(propertyName) {
        const window = root[propertyName]
        if (window === null || now < window.resets_at)
            return

        if (!window.resetting)
            root[propertyName] = normalizedWindow(window)

        const epochKey = propertyName + ":" + window.resets_at
        if (refreshedResetEpochs[epochKey])
            return
        refreshedResetEpochs[epochKey] = true
        refresh(true)
    }

    function checkWindowResets() {
        checkWindowReset("primary")
        checkWindowReset("secondary")
    }

    Component.onCompleted: {
        cacheFile.reload()
        errorFile.reload()
    }

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.refresh(false)
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            root.now = Math.floor(Date.now() / 1000)
            root.checkWindowResets()
        }
    }

    FileView {
        id: cacheFile
        path: root.cachePath
        preload: false
        watchChanges: true
        onLoaded: {
            root.loadUsage(cacheFile.text())
            root.finishInitialUsageLoad()
        }
        onLoadFailed: function(error) {
            root.finishInitialUsageLoad()
        }
        onFileChanged: reload()
    }

    FileView {
        id: errorFile
        path: root.errorPath
        preload: false
        watchChanges: true
        onLoaded: root.loadError(errorFile.text())
        onLoadFailed: function(error) {
            if (error === FileViewError.FileNotFound) {
                root.errorCategory = ""
                root.errorDetail = ""
            }
        }
        onFileChanged: reload()
    }
}
