package com.reelhouse.android.data

import org.json.JSONObject

// Push notifications - GET /api/push/status. `enabled` is the admin's master switch (web Settings
// -> Push Notifications); androidConfigured is whether the server holds the Firebase credentials it
// needs to reach Android at all. The three category flags are what the server will send.
data class PushStatus(
    val enabled: Boolean,
    val appleConfigured: Boolean,
    val androidConfigured: Boolean,
    // This signed-in account's registered devices, every platform.
    val myDevices: Int,
    val newEpisodes: Boolean,
    val downloads: Boolean,
    val loginAlerts: Boolean,
)

// POST /api/push/test: how the send to the caller's own devices went. `removed` counts tokens the
// push service reported dead, which the server dropped.
data class PushDeliveryReport(
    val attempted: Int,
    val delivered: Int,
    val failed: Int,
    val removed: Int,
)

internal fun parsePushStatus(json: JSONObject): PushStatus = PushStatus(
    enabled = json.optBoolean("enabled"),
    appleConfigured = json.optBoolean("appleConfigured"),
    androidConfigured = json.optBoolean("androidConfigured"),
    myDevices = json.optInt("myDevices"),
    newEpisodes = json.optBoolean("newEpisodes"),
    downloads = json.optBoolean("downloads"),
    loginAlerts = json.optBoolean("loginAlerts"),
)

internal fun parsePushDeliveryReport(json: JSONObject): PushDeliveryReport = PushDeliveryReport(
    attempted = json.optInt("attempted"),
    delivered = json.optInt("delivered"),
    failed = json.optInt("failed"),
    removed = json.optInt("removed"),
)

// The one line Settings -> Notifications shows about the server side. `firebaseReady` is whether
// this build has a Firebase app at all (see push/PushSupport) - without one nothing else matters.
internal fun pushStatusSummary(firebaseReady: Boolean, status: PushStatus?, unavailable: Boolean): String = when {
    !firebaseReady -> "Push isn't set up in this build."
    unavailable -> "This server doesn't send push notifications - it may need updating."
    status == null -> "Checking the server…"
    !status.enabled -> "Off on the server — an admin can turn it on in the web Settings → Push Notifications."
    !status.androidConfigured ->
        "On, but the server isn't set up to reach Android yet — an admin can add the Firebase " +
            "credentials in the web Settings → Push Notifications."
    else -> {
        val kinds = listOfNotNull(
            "new podcast episodes".takeIf { status.newEpisodes },
            "finished downloads".takeIf { status.downloads },
            "sign-in alerts".takeIf { status.loginAlerts },
        )
        val sends = if (kinds.isEmpty()) "On, though every kind of notification is switched off." else "On: ${kinds.joinToString(", ")}."
        val devices = when (status.myDevices) {
            0 -> "No devices of yours are registered yet."
            1 -> "1 device of yours is registered."
            else -> "${status.myDevices} devices of yours are registered."
        }
        "$sends $devices"
    }
}

internal fun pushTestSummary(report: PushDeliveryReport): String = when {
    report.attempted == 0 -> "No devices of yours are registered, so there was nothing to send to."
    report.delivered == report.attempted ->
        if (report.delivered == 1) "Sent to 1 device." else "Sent to ${report.delivered} devices."
    report.delivered > 0 -> "Sent to ${report.delivered} of ${report.attempted} devices."
    else -> "The server tried ${report.attempted} device(s) but none accepted it." +
        if (report.removed > 0) " ${report.removed} stale registration(s) were removed." else ""
}
