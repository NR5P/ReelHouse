package com.reelhouse.android.data

import java.time.Instant

// SettingsSecrets.Mask on the server. Any stored secret is replaced by this on its way out, and
// sending it back unchanged means "keep the one you have".
const val SECRET_MASK: String = "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022"

data class AuthStatus(
    val enabled: Boolean,
    val configured: Boolean,
    val authenticated: Boolean,
    val username: String?,
    // Absent on servers older than the multi-account update - treated as Admin everywhere it's
    // read, since that's what every pre-upgrade single-account login effectively was.
    val role: String?,
)

data class Account(
    val id: String,
    val username: String,
    val displayName: String?,
    val role: String,
    val createdAt: Instant,
)

data class DiagnosticEntry(
    val id: Long,
    val timestamp: Instant,
    val level: DiagnosticLevel,
    val message: String,
)

enum class DiagnosticLevel {
    INFO,
    NOTICE,
    ERROR,
}

enum class ConnectionState(val label: String) {
    NOT_CONFIGURED("Set server"),
    CHECKING("Connecting…"),
    ONLINE("Connected"),
    AUTHENTICATION_REQUIRED("Sign in required"),
    OFFLINE("Offline"),
}

class ReelHouseApiException(
    val statusCode: Int,
    override val message: String,
) : Exception(message)

// The server-side settings schema - which sections exist and what fields they contain, served
// by GET /api/settings/schema and shared verbatim with the web dashboard and the iOS/macOS app.
// A settings section added on the server appears in this app with no update; these classes only
// mirror the shapes, ServerSettingsScreen renders them.

data class SettingsFieldOption(val value: String, val label: String)

// A "look this up for me" button on a text field (today: LOCATION's Town or City, which fills in
// latitude and longitude). Pure data like SettingsAction - an endpoint taking ?query= - so nothing
// here is location-specific, and a field without one is just a text box.
data class SettingsLookup(
    val label: String,
    val tip: String,
    val endpoint: String,
)

// One option a lookup came back with: something to show in the list, and the field values to write
// if it's picked. The keys are field names in the same section; this app applies the ones it
// recognises and ignores the rest, so a newer server can't break an older build.
data class SettingsLookupCandidate(
    val label: String,
    val values: Map<String, Any>,
)

// Where a text field's likely values can be fetched from (today: the models pulled on the Ollama
// machine, for the two Model boxes). Pure data like SettingsLookup - an endpoint taking no
// parameters - so nothing here is Ollama-specific.
//
// A field carrying one is drawn as a dropdown, but never as a plain one: whatever is saved now is
// always in the list, and "type a name instead" is always the last entry. The list is only what is
// installed at this moment, and naming a model you are about to pull has to keep working.
data class SettingsOptionsSource(
    val label: String,
    val tip: String,
    val endpoint: String,
    // Shown when the endpoint answers with an empty list. From the server because it is the one
    // message that names what to go and do ("ollama pull ..."), which this app shouldn't know.
    val emptyMessage: String,
    // Shown after picking "type a name instead", from the server for the same reason: a model tag,
    // a model id and a URL each want different advice, and this app shouldn't know which is which.
    val typeItMessage: String,
)

data class SettingsField(
    val name: String,
    val label: String,
    // "text", "number", "checkbox", "password", "select", or "csv". Anything unrecognized is
    // rendered read-only rather than guessed at.
    val type: String,
    val tip: String,
    val options: List<SettingsFieldOption>,
    // Bounds for a "number" field, mirroring the [Range] on the server's DTO property. Carried so
    // this app can say "must be between 0 and 1" under the box instead of sending the value and
    // relaying whatever the server's rejection said - the schema has always published these, and
    // this app was simply dropping them on the floor.
    val min: Double?,
    val max: Double?,
    // True when the number is a whole one (an int or long on the server). Without it there is no
    // telling a port from a free-space threshold in GB: both are plain numbers with no step, and
    // only one of them may be 3.7. Null against a server predating the flag, which has to mean
    // "apply no extra restriction" rather than guessing.
    val integer: Boolean?,
    // Absent on all but a handful of text fields - see SettingsLookup.
    val lookup: SettingsLookup?,
    // Absent on all but a handful of text fields - see SettingsOptionsSource. Null against a
    // server that predates it, which has to mean "an ordinary text box".
    val optionsSource: SettingsOptionsSource?,
    val requiresRestart: Boolean,
)

// An extra button a section offers (currently just Bridge's "re-run setup wizard") - pure data,
// an endpoint to call, so no client needs bespoke code per action.
data class SettingsAction(
    val label: String,
    val tip: String,
    val endpoint: String,
    val method: String,
)

data class SettingsSection(
    val key: String,
    val title: String,
    val endpoint: String,
    val description: String,
    val fields: List<SettingsField>,
    val extraAction: SettingsAction?,
    // Which heading this section belongs under, and where that heading sorts. Both come from the
    // server (SettingsGroups) so this app and the web dashboard divide the settings the same way
    // without either holding its own copy of the grouping. Defaulted rather than nullable so an
    // older server that predates grouping still renders - as one unnamed group, i.e. the flat list
    // this screen had before.
    val group: String = "",
    val groupOrder: Int = Int.MAX_VALUE,
    // Whether this section shows in basic mode. Advanced sections are the ones a typical install
    // never needs to touch.
    val basic: Boolean = false,
    // Which service has to restart for requiresRestart fields here to take effect. Every section
    // but INTERNET EXPOSED MODE is the bridge.
    val restartService: String = "bridge",
    // Where to GET this section's current values, when they aren't in the bulk /api/settings
    // snapshot - only INTERNET EXPOSED MODE sets it.
    val dataEndpoint: String? = null,
) {
    val needsRestart: Boolean get() = fields.any { it.requiresRestart }

    // Field tips are searched as well as labels: they're where a setting is described in the words
    // someone would actually type - nobody searches for "nuisanceAdvisor".
    fun matches(query: String): Boolean =
        title.contains(query, ignoreCase = true) ||
            description.contains(query, ignoreCase = true) ||
            fields.any {
                it.label.contains(query, ignoreCase = true) || it.tip.contains(query, ignoreCase = true)
            }
}
