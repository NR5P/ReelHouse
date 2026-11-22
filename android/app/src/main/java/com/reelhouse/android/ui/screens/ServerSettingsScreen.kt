package com.reelhouse.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.reelhouse.android.data.SettingsField
import com.reelhouse.android.data.SettingsFieldOption
import com.reelhouse.android.data.SettingsLookup
import com.reelhouse.android.data.SettingsLookupCandidate
import com.reelhouse.android.data.SettingsOptionsSource
import com.reelhouse.android.data.SettingsSection
import com.reelhouse.android.ui.ReelHouseUiState
import com.reelhouse.android.ui.ReelHouseViewModel
import com.reelhouse.android.ui.theme.ReelHouseGold
import com.reelhouse.android.ui.theme.ReelHouseRed
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import com.reelhouse.android.ui.components.SaveFeedbackHost
import com.reelhouse.android.ui.components.rememberSaveFeedback
import com.reelhouse.android.ui.components.SaveButton

// Every server settings section, rendered generically from GET /api/settings/schema - the same
// definitions the web dashboard and the iOS/macOS app render, so a section added on the server
// appears here with no app update. A renderer, not a settings screen: it knows how to draw a
// "number" or "select" field, and nothing about what any particular section means.
//
// Reached only through the Admin-gated part of SettingsScreen - the whole /api/settings group
// is AdminOnly server-side and would 403 a Viewer anyway.
@Composable
fun ServerSettingsScreen(
    state: ReelHouseUiState,
    model: ReelHouseViewModel,
    onBack: () -> Unit,
) {
    var sections by remember { mutableStateOf<List<SettingsSection>>(emptyList()) }
    var snapshot by remember { mutableStateOf<JSONObject?>(null) }
    // Values for the sections that keep them outside the bulk snapshot, keyed by section key.
    var externalData by remember { mutableStateOf<Map<String, JSONObject>>(emptyMap()) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<SettingsSection?>(null) }
    var search by remember { mutableStateOf("") }
    var showAdvanced by remember { mutableStateOf(model.showAdvancedSettings) }

    LaunchedEffect(Unit) {
        try {
            val loaded = model.settingsSchema()
            sections = loaded
            snapshot = model.settingsSnapshot()

            // A failure here leaves that one section rendering empty rather than failing the whole
            // screen - the same outcome a missing snapshot key already has, and better than losing
            // the other 35 sections because one extra request didn't come back.
            externalData = buildMap {
                for (section in loaded) {
                    val endpoint = section.dataEndpoint ?: continue
                    runCatching { model.settingsSectionData(endpoint) }.getOrNull()?.let { put(section.key, it) }
                }
            }
        } catch (error: Exception) {
            loadError = error.message ?: "Could not load server settings."
        }
    }

    val openSection = selected
    if (openSection != null) {
        ServerSettingsSectionEditor(
            section = openSection,
            initialData = if (openSection.dataEndpoint != null) {
                externalData[openSection.key]
            } else {
                snapshot?.optJSONObject(openSection.key)
            },
            model = model,
            onBack = { selected = null },
        )
        return
    }

    // Both filters at once, because they interact: a search has to reach an advanced section while
    // the list is in basic mode, or searching for "mqtt" in basic mode finds nothing and looks
    // broken. A non-empty search therefore overrides the mode entirely.
    val query = search.trim()
    val visible = sections.filter { section ->
        if (query.isNotEmpty()) section.matches(query) else showAdvanced || section.basic
    }

    // Sections keep their server order within a group - the descriptions lean on it ("see VISION
    // ROUTING below"), so it isn't this app's to re-sort.
    val groups = visible
        .groupBy { it.group.ifEmpty { "Other" } }
        .toList()
        .sortedWith(compareBy({ entry -> entry.second.minOf { it.groupOrder } }, { it.first }))

    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Server Settings", state)
        when {
            loadError != null -> Column(
                Modifier.fillMaxWidth().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(loadError.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = onBack) { Text("Back") }
            }

            sections.isEmpty() -> Text(
                "Loading…",
                modifier = Modifier.padding(24.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            else -> LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                item {
                    TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                        Text("Back to Settings", modifier = Modifier.weight(1f).padding(start = 8.dp))
                    }
                }
                item {
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        label = { Text("Search settings") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
                    )
                }
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Show advanced settings", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "Basic shows the settings most people change. Searching looks through both.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Switch(
                            checked = showAdvanced,
                            onCheckedChange = {
                                showAdvanced = it
                                model.showAdvancedSettings = it
                            },
                        )
                    }
                }

                // A heading, not another collapsible layer: nesting would put every field two taps
                // away, and the web dashboard draws the same headings above flat accordions.
                for ((groupName, groupSections) in groups) {
                    item(key = "group-$groupName") {
                        Text(
                            groupName.uppercase(),
                            style = MaterialTheme.typography.labelMedium,
                            color = ReelHouseGold,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 2.dp),
                        )
                    }
                    items(groupSections, key = { it.key }) { section ->
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp)
                                .clickable { selected = section },
                        ) {
                            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(section.title, style = MaterialTheme.typography.titleSmall, color = ReelHouseGold)
                                Text(
                                    section.description,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 2,
                                )
                            }
                        }
                    }
                }

                if (groups.isEmpty()) {
                    item {
                        Text(
                            "No settings match \"$search\".",
                            modifier = Modifier.padding(24.dp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                item { Spacer(Modifier.padding(8.dp)) }
            }
        }
    }
}

@Composable
private fun ServerSettingsSectionEditor(
    section: SettingsSection,
    initialData: JSONObject?,
    model: ReelHouseViewModel,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()

    // ReelHouse is one server process, and this app is talking to it: a restart drops the
    // connection in use for a few seconds. The schema names the service to restart; anything
    // other than "dashboard" is passed through as the server named it.
    val restartsDashboard = section.restartService == "dashboard"

    // Field values keyed by schema field name (dotted paths like "apple.teamId" stay flat here;
    // nesting is reassembled when building the save payload).
    val text = remember(section.key) {
        mutableStateMapOf<String, String>().apply {
            for (field in section.fields) {
                if (field.type == "checkbox") continue
                val value = readPath(initialData, field.name)
                this[field.name] = when {
                    field.type == "select" ->
                        (value as? String) ?: section.fields.first { it.name == field.name }
                            .options.firstOrNull()?.value.orEmpty()
                    value is JSONArray -> buildList {
                        for (index in 0 until value.length()) add(value.optString(index))
                    }.joinToString(", ")
                    value == null || value == JSONObject.NULL -> ""
                    value is Double -> if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
                    else -> value.toString()
                }
            }
        }
    }
    val flags = remember(section.key) {
        mutableStateMapOf<String, Boolean>().apply {
            for (field in section.fields) {
                if (field.type == "checkbox") this[field.name] = readPath(initialData, field.name) == true
            }
        }
    }

    // Lookup state, keyed by the field the button belongs to rather than held as three loose
    // properties - the schema can grow a second lookup field without this screen changing.
    val lookupResults = remember(section.key) { mutableStateMapOf<String, List<SettingsLookupCandidate>>() }
    val lookupNotes = remember(section.key) { mutableStateMapOf<String, LookupNote>() }
    var lookupBusy by remember(section.key) { mutableStateOf<String?>(null) }

    // The values fetched for the fields that carry an optionsSource (OLLAMA's Model, from what is
    // pulled on the box). A field with no entry here falls back to its plain text box - which is
    // exactly what it was before this existed, so a server that can't answer costs nothing.
    val fieldOptions = remember(section.key) { mutableStateMapOf<String, List<SettingsFieldOption>>() }
    val optionsNotes = remember(section.key) { mutableStateMapOf<String, LookupNote>() }

    // Fields where the dropdown has been swapped for the keyboard on purpose, because the wanted
    // value isn't installed yet. Never sticky beyond this screen.
    val typingManually = remember(section.key) { mutableStateMapOf<String, Boolean>() }

    var isSaving by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var errors by remember { mutableStateOf<List<String>>(emptyList()) }
    val feedback = rememberSaveFeedback()
    var confirmRestart by remember { mutableStateOf(false) }
    var confirmAction by remember { mutableStateOf(false) }

    // The audio folder picker, shown in place of the section while choosing (Music → Libraries,
    // Podcasts → Download folder). Held here so the form's typed values survive the trip.
    var audioPicker by remember { mutableStateOf<Pair<String, (String) -> Unit>?>(null) }
    val libraryForm = remember(section.key) { com.reelhouse.android.ui.audio.LibraryForm() }

    // One request per field that asks for one, when this section is opened - the phone reaches a
    // section by drilling into it, so there is nothing further to defer. A failure is not worth a
    // banner: the field stays the text box it has always been, with the server's own explanation
    // underneath it.
    LaunchedEffect(section.key) {
        for (field in section.fields) {
            val source = field.optionsSource ?: continue
            try {
                val options = model.settingsOptions(source)
                if (options.isEmpty()) {
                    optionsNotes[field.name] = LookupNote(source.emptyMessage, isError = false)
                } else {
                    fieldOptions[field.name] = options
                    optionsNotes.remove(field.name)
                }
            } catch (error: Exception) {
                optionsNotes[field.name] = LookupNote(
                    error.message ?: "Couldn't read the list from the server.",
                    isError = true,
                )
            }
        }
    }

    fun runLookup(field: SettingsField, lookup: SettingsLookup) {
        val query = (text[field.name] ?: "").trim()
        if (query.isEmpty()) {
            lookupResults[field.name] = emptyList()
            lookupNotes[field.name] = LookupNote("Type a town or city first.", isError = true)
            return
        }

        scope.launch {
            lookupBusy = field.name
            lookupNotes.remove(field.name)
            try {
                val candidates = model.settingsLookup(lookup, query)
                lookupResults[field.name] = candidates
                if (candidates.isEmpty()) {
                    lookupNotes[field.name] = LookupNote(
                        "Nothing found for \"$query\". Try adding a state or country, or enter the " +
                            "coordinates yourself.",
                        isError = true,
                    )
                }
            } catch (error: Exception) {
                lookupResults[field.name] = emptyList()
                // The server's message separates "this machine has no route to the internet" from
                // "the lookup service said no", and each ends with what to do instead.
                lookupNotes[field.name] = LookupNote(error.message ?: "The lookup failed.", isError = true)
            } finally {
                lookupBusy = null
            }
        }
    }

    // Writes into the section's *other* fields, which is the whole point: the values wanted are
    // the ones nobody can type from memory. Names this section doesn't have are skipped, so a
    // server that starts returning a third value can't upset an app that knows two.
    fun applyCandidate(field: SettingsField, candidate: SettingsLookupCandidate) {
        for ((name, value) in candidate.values) {
            val target = section.fields.firstOrNull { it.name == name } ?: continue
            if (target.type == "checkbox") {
                flags[name] = value == true
            } else {
                text[name] = when {
                    value == JSONObject.NULL -> ""
                    // Same "don't show a port as 1883.0" rule the field seeding above uses.
                    value is Double && value == value.toLong().toDouble() -> value.toLong().toString()
                    else -> value.toString()
                }
            }
        }
        lookupResults[field.name] = emptyList()
        lookupNotes[field.name] = LookupNote("Filled in from ${candidate.label}. Save to keep it.", isError = false)
    }

    fun save() {
        val payload = JSONObject()
        val problems = mutableListOf<String>()
        for (field in section.fields) {
            val value: Any = when (field.type) {
                "checkbox" -> flags[field.name] ?: false
                "number" -> {
                    val raw = (text[field.name] ?: "").trim()
                    val number = raw.toDoubleOrNull()
                    if (number == null) {
                        problems.add("${field.label} must be a number.")
                        continue
                    }
                    // Checked here as well as on the server so the message names the box to go
                    // and fix, and so nothing the server would refuse leaves the phone. The
                    // server validates it again on arrival regardless - see SaveSectionAsync.
                    val problem = boundsProblem(field, number)
                    if (problem != null) {
                        problems.add(problem)
                        continue
                    }
                    // org.json would serialize 30.0 as "30.0", which the server's int binding
                    // refuses - so integral values go as longs.
                    if (number == number.toLong().toDouble()) number.toLong() else number
                }
                "csv" -> JSONArray((text[field.name] ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() })
                else -> text[field.name] ?: ""
            }
            writePath(payload, field.name, value)
        }
        if (problems.isNotEmpty()) {
            errors = problems
            return
        }

        scope.launch {
            isSaving = true
            statusMessage = null
            errors = emptyList()
            try {
                val restartRequired = model.saveSettingsSection(section.endpoint, payload)
                // The banner and the button say it saved; the inline line only keeps what's still
                // worth reading once they've gone - that a restart stands between save and effect.
                if (restartRequired) {
                    statusMessage = "Saved. Takes effect after the server restarts - use the restart button below."
                    feedback.saved("Saved - restart the server to apply")
                } else {
                    feedback.saved()
                }
            } catch (error: Exception) {
                errors = (error.message ?: "Save failed.").split("\n")
                feedback.failed("Not saved")
            } finally {
                isSaving = false
            }
        }
    }

    audioPicker?.let { (start, use) ->
        androidx.activity.compose.BackHandler { audioPicker = null }
        com.reelhouse.android.ui.audio.AudioFolderPicker(
            state = model.state.value,
            model = model,
            startPath = start,
            onUse = { chosen -> use(chosen); audioPicker = null },
            onClose = { audioPicker = null },
        )
        return
    }

    SaveFeedbackHost(feedback) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                    Text(section.title, modifier = Modifier.weight(1f).padding(start = 8.dp), color = ReelHouseGold)
                }
            }
            item {
                Text(
                    section.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
            items(section.fields, key = { it.name }) { field ->
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    SettingsFieldControl(
                        field = field,
                        textValue = text[field.name] ?: "",
                        onText = { text[field.name] = it },
                        flagValue = flags[field.name] ?: false,
                        onFlag = { flags[field.name] = it },
                        // Null keeps the plain text box: no list fetched, or the fetch failed.
                        fetchedOptions = fieldOptions[field.name]
                            ?.takeIf { typingManually[field.name] != true },
                        onTypeManually = {
                            typingManually[field.name] = true
                            field.optionsSource?.let { source ->
                                optionsNotes[field.name] = LookupNote(source.typeItMessage, isError = false)
                            }
                        },
                    )

                    // Why there's a box here rather than the promised list, and the way back to it
                    // once there is one.
                    field.optionsSource?.let { source ->
                        optionsNotes[field.name]?.let { note ->
                            Text(
                                note.text,
                                color = if (note.isError) ReelHouseRed else MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        if (typingManually[field.name] == true && fieldOptions[field.name] != null) {
                            TextButton(
                                onClick = {
                                    typingManually[field.name] = false
                                    optionsNotes.remove(field.name)
                                },
                            ) {
                                Text("Back to ${source.label}")
                            }
                        }
                    }
                    Text(
                        if (field.requiresRestart) "${field.tip} (Restart required.)" else field.tip,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    // Below the tip, not above it: the tip describes the box, and a candidate list
                    // sitting between the two reads as though the explanation belongs to the
                    // results.
                    field.lookup?.let { lookup ->
                        val busy = lookupBusy == field.name
                        OutlinedButton(
                            onClick = { runLookup(field, lookup) },
                            enabled = !busy,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(if (busy) "Looking…" else lookup.label.replaceFirstChar(Char::uppercase))
                        }
                        lookupNotes[field.name]?.let { note ->
                            Text(
                                note.text,
                                color = if (note.isError) ReelHouseRed else ReelHouseGold,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        // A whole row each: the difference between the right Holland and the wrong
                        // one is usually the county at the end of the name.
                        for (candidate in lookupResults[field.name].orEmpty()) {
                            TextButton(
                                onClick = { applyCandidate(field, candidate) },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    candidate.label,
                                    modifier = Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                }
            }
            item {
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    statusMessage?.let { Text(it, color = ReelHouseGold, style = MaterialTheme.typography.bodySmall) }
                    errors.forEach { Text(it, color = ReelHouseRed, style = MaterialTheme.typography.bodySmall) }
                    SaveButton(feedback, isSaving, onClick = ::save, modifier = Modifier.fillMaxWidth())
                    section.extraAction?.let { action ->
                        OutlinedButton(onClick = { confirmAction = true }, modifier = Modifier.fillMaxWidth()) {
                            Text(action.label.replaceFirstChar(Char::uppercase))
                        }
                    }
                    if (section.needsRestart) {
                        OutlinedButton(onClick = { confirmRestart = true }, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                if (restartsDashboard) "Restart Server" else "Restart ${section.restartService.replaceFirstChar(Char::uppercase)} Service",
                                color = ReelHouseRed,
                            )
                        }
                    }
                }
            }
            // Music & Podcasts (MUSIC_AND_PODCASTS.md §1): the library list and the download
            // folder's picker sit under the schema's own fields.
            if (section.key == "music") {
                item {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        com.reelhouse.android.ui.audio.MusicLibrariesPanel(model.audio, libraryForm) { start, use -> audioPicker = start to use }
                    }
                }
            }
            if (section.key == "podcasts") {
                item {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        com.reelhouse.android.ui.audio.PodcastsFolderPanel(model.audio) {
                            audioPicker = (text["downloadFolder"] ?: "") to { chosen -> text["downloadFolder"] = chosen }
                        }
                    }
                }
            }
            item { Spacer(Modifier.padding(12.dp)) }
        }
    }

    if (confirmRestart) {
        AlertDialog(
            onDismissRequest = { confirmRestart = false },
            title = { Text(if (restartsDashboard) "Restart the server?" else "Restart the ${section.restartService} service?") },
            text = {
                Text(
                    "Saved restart-required settings take effect after the restart. Anything playing " +
                        "from the server pauses, and this app loses its connection for a few seconds " +
                        "and reconnects on its own.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRestart = false
                    scope.launch {
                        statusMessage = "Restarting - the server should be back in a few seconds…"
                        errors = emptyList()
                        try {
                            model.restartServer(section.restartService)
                        } catch (error: Exception) {
                            statusMessage = null
                            // The refusal for an unsupervised process is worth showing verbatim -
                            // it explains the systemd situation better than a generic error.
                            errors = listOf(error.message ?: "Restart failed.")
                        }
                    }
                }) { Text("Restart", color = ReelHouseRed) }
            },
            dismissButton = { TextButton(onClick = { confirmRestart = false }) { Text("Cancel") } },
        )
    }

    val action = section.extraAction
    if (confirmAction && action != null) {
        AlertDialog(
            onDismissRequest = { confirmAction = false },
            title = { Text(action.label.replaceFirstChar(Char::uppercase)) },
            text = { Text(action.tip) },
            confirmButton = {
                TextButton(onClick = {
                    confirmAction = false
                    scope.launch {
                        try {
                            // The server's own sentence when it has one - "Test email sent to
                            // you@example.com." is what someone pressed the button to find out.
                            val outcome = model.runSettingsAction(action) ?: "Done."
                            statusMessage = outcome
                            feedback.note(outcome)
                        } catch (error: Exception) {
                            errors = listOf(error.message ?: "Action failed.")
                            feedback.failed("${action.label.replaceFirstChar(Char::uppercase)} failed")
                        }
                    }
                }) { Text("Continue") }
            },
            dismissButton = { TextButton(onClick = { confirmAction = false }) { Text("Cancel") } },
        )
    }
}

// What a lookup has to say for itself between presses - "nothing found", "filled in from X", or
// whatever the server explained went wrong. Kept apart from the section's save errors so a failed
// lookup doesn't read as a failed save.
private data class LookupNote(val text: String, val isError: Boolean)

@Composable
private fun SettingsFieldControl(
    field: SettingsField,
    textValue: String,
    onText: (String) -> Unit,
    flagValue: Boolean,
    onFlag: (Boolean) -> Unit,
    // What the server says this field's value can be (SettingsOptionsSource), when it could be
    // asked and the user hasn't chosen to type instead. Null everywhere else, which is every
    // field but two and every server older than this feature.
    fetchedOptions: List<SettingsFieldOption>? = null,
    onTypeManually: () -> Unit = {},
) {
    when (field.type) {
        "checkbox" -> Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(field.label, modifier = Modifier.weight(1f))
            Switch(checked = flagValue, onCheckedChange = onFlag)
        }

        "select" -> SettingsSelectField(field, textValue, onText)

        "password" -> OutlinedTextField(
            value = textValue,
            onValueChange = onText,
            modifier = Modifier.fillMaxWidth(),
            label = { Text(field.label) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        )

        "number" -> OutlinedTextField(
            value = textValue,
            onValueChange = onText,
            modifier = Modifier.fillMaxWidth(),
            label = { Text(field.label) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        )

        "text", "csv" -> if (fetchedOptions != null) {
            SettingsFetchedOptionsField(field, fetchedOptions, textValue, onText, onTypeManually)
        } else {
            OutlinedTextField(
                value = textValue,
                onValueChange = onText,
                modifier = Modifier.fillMaxWidth(),
                label = { Text(field.label) },
                singleLine = true,
                placeholder = if (field.type == "csv") {
                    { Text("comma, separated") }
                } else {
                    null
                },
            )
        }

        // A field type this app version doesn't know - shown read-only rather than guessed at.
        else -> Row(Modifier.fillMaxWidth()) {
            Text(field.label, modifier = Modifier.weight(1f))
            Text(textValue, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSelectField(field: SettingsField, value: String, onValue: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = field.options.firstOrNull { it.value == value }?.label ?: value

    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text(field.label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (option in field.options) {
                DropdownMenuItem(
                    text = { Text(option.label) },
                    onClick = {
                        onValue(option.value)
                        expanded = false
                    },
                )
            }
        }
    }
}

// A field whose values the server went and fetched - OLLAMA's Model, from what is pulled on the
// box. A dropdown, with two things that keep it honest: whatever is saved now is always in the
// list even if the server didn't return it (so opening it can't quietly change a working
// setting), and the last entry always hands the field back to the keyboard (so a model you are
// about to pull can still be named).
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SettingsFetchedOptionsField(
    field: SettingsField,
    options: List<SettingsFieldOption>,
    value: String,
    onValue: (String) -> Unit,
    onTypeManually: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }

    val entries = if (options.any { it.value == value } || value.isEmpty()) {
        options
    } else {
        listOf(SettingsFieldOption(value, "$value (not listed)")) + options
    }
    val selectedLabel = entries.firstOrNull { it.value == value }?.label ?: value

    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text(field.label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (option in entries) {
                DropdownMenuItem(
                    text = { Text(option.label) },
                    onClick = {
                        onValue(option.value)
                        expanded = false
                    },
                )
            }
            DropdownMenuItem(
                text = { Text("Type a name instead…") },
                onClick = {
                    onTypeManually()
                    expanded = false
                },
            )
        }
    }
}

// Schema field names can be dotted paths into nested objects ("apple.teamId") - the same
// convention the dashboard's readPath/writePath and the iOS SettingsValue helpers use.
private fun readPath(data: JSONObject?, path: String): Any? {
    var node: Any? = data ?: return null
    for (segment in path.split(".")) {
        node = (node as? JSONObject)?.opt(segment) ?: return null
    }
    return node
}

private fun writePath(target: JSONObject, path: String, value: Any) {
    val segments = path.split(".")
    var node = target
    for (segment in segments.dropLast(1)) {
        node = node.optJSONObject(segment) ?: JSONObject().also { node.put(segment, it) }
    }
    node.put(segments.last(), value)
}

// What is wrong with a number the user typed into a settings box, or null if nothing is. The
// bounds come from the schema, which mirrors the [Range] the server enforces - so this says the
// same thing the save would have said, in the same words, without the round trip.
private fun boundsProblem(field: SettingsField, number: Double): String? {
    if (field.integer == true && number != number.toLong().toDouble()) {
        return "${field.label} must be a whole number."
    }
    val min = field.min
    val max = field.max
    if (min != null && max != null && (number < min || number > max)) {
        return "${field.label} must be between ${formatBound(min)} and ${formatBound(max)}."
    }
    if (min != null && number < min) return "${field.label} must be $min or more."
    if (max != null && number > max) return "${field.label} must be $max or less."
    return null
}

// The same "don't show a port as 1883.0" rule the field seeding uses, applied to the bounds so an
// error reads "between 1 and 65535" rather than "between 1.0 and 65535.0".
private fun formatBound(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
