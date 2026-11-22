window.ReelHouseSettings = (function () {
  // The section/field definitions come from GET /api/settings/schema, where the iOS, Apple TV
  // and Android apps read the very same definitions - one source for every platform's settings forms (see SettingsSchema.cs).
  // Everything below only knows how to *render* a section, not what any section contains.

  // Schema field names can be dotted paths into nested settings objects - these two are the only
  // places that need to know that.
  function readPath(data, path) {
    let value = data;
    for (const segment of path.split(".")) {
      if (value == null) return undefined;
      value = value[segment];
    }
    return value;
  }

  function writePath(target, path, value) {
    const segments = path.split(".");
    let node = target;
    for (let i = 0; i < segments.length - 1; i++) {
      node = node[segments[i]] ??= {};
    }
    node[segments[segments.length - 1]] = value;
  }


  const WIDE_TYPES = new Set(["checkbox", "password", "csv"]);

  // A text field that can look itself up (schema field.lookup): the box gets a button beside it,
  // and what comes back fills in *other* fields of the same section. No section uses one today;
  // it stays because the schema format allows it and the apps render it too. The candidate says
  // which field names it sets, and this writes to whichever of them are on screen.
  function buildLookup(field, input) {
    const wrap = document.createElement("div");
    wrap.className = "field-lookup";

    const row = document.createElement("div");
    row.className = "field-lookup-row";
    const findBtn = document.createElement("button");
    findBtn.type = "button";
    findBtn.className = "field-toggle-btn";
    findBtn.textContent = field.lookup.label;
    findBtn.dataset.tip = field.lookup.tip;
    findBtn.setAttribute("data-tip-right", "");
    row.append(input, findBtn);

    const results = document.createElement("div");
    results.className = "field-lookup-results";
    wrap.append(row, results);

    function say(message, isError) {
      results.textContent = "";
      const note = document.createElement("p");
      note.className = "field-lookup-note" + (isError ? " field-lookup-error" : "");
      note.textContent = message;
      results.appendChild(note);
    }

    // Writing into siblings rather than into this field: a lookup exists precisely because the
    // values you want are not the thing you can type. Anything the candidate names that isn't
    // rendered here is skipped, so an older page meeting a newer server writes what it can.
    function apply(candidate) {
      const grid = wrap.closest(".field-grid");
      for (const [name, value] of Object.entries(candidate.values || {})) {
        const target = grid && grid.querySelector(`[data-field="${name}"]`);
        if (!target) continue;
        target.value = value;
        target.dispatchEvent(new Event("change", { bubbles: true }));
      }
      say(`Filled in from ${candidate.label}. Press save to keep it.`, false);
    }

    async function find() {
      const query = input.value.trim();
      if (!query) {
        say("Type something to look up first.", true);
        input.focus();
        return;
      }

      findBtn.disabled = true;
      say("Looking…", false);
      try {
        const response = await fetch(`${field.lookup.endpoint}?query=${encodeURIComponent(query)}`);
        const payload = await response.json().catch(() => null);
        if (!response.ok) {
          // The server's own message is the useful one here - it distinguishes "this machine has
          // no route to the internet" from "the lookup service said no", and says what to do.
          say((payload && payload.error) || `Lookup failed (HTTP ${response.status}).`, true);
          return;
        }
        const candidates = (payload && payload.results) || [];
        if (candidates.length === 0) {
          say(`Nothing found for "${query}". Try different words, or fill the fields in yourself.`, true);
          return;
        }

        results.textContent = "";
        const list = document.createElement("ul");
        list.className = "field-lookup-list";
        for (const candidate of candidates) {
          const item = document.createElement("li");
          const choice = document.createElement("button");
          choice.type = "button";
          choice.className = "field-lookup-choice";
          choice.textContent = candidate.label;
          choice.addEventListener("click", () => apply(candidate));
          item.appendChild(choice);
          list.appendChild(item);
        }
        results.appendChild(list);
      } catch {
        say("Couldn't reach this server to run the lookup. Check the connection, or fill the fields in yourself.", true);
      } finally {
        findBtn.disabled = false;
      }
    }

    findBtn.addEventListener("click", find);
    // Enter is what a search box invites. There's no <form> here, so nothing to suppress.
    input.addEventListener("keydown", event => {
      if (event.key === "Enter") find();
    });

    return wrap;
  }

  // A text field whose likely values the server can go and fetch (schema field.optionsSource):
  // MOVIE DOWNLOADS' Mullvad location, filled from Mullvad's current server list. Rendered as a
  // dropdown *plus* a way back to the text box, never as a plain select - the list is only what
  // exists at this moment, and typing a code that isn't listed has to keep working.
  //
  // The <input> stays in the DOM and stays the one thing carrying data-field, so saveSection is
  // untouched by any of this: the dropdown writes into the box, exactly as the "use recommended"
  // button does. If the fetch fails, or this page is talking to a server too old to have the
  // endpoint, what's left on screen is that box - which is all this field ever was before.
  function buildOptionsSource(field, input, loaders) {
    const source = field.optionsSource;

    const wrap = document.createElement("div");
    wrap.className = "field-options";

    const select = document.createElement("select");
    select.className = "field-input";
    select.hidden = true;
    // Deliberately no data-field: two elements answering to the same name would leave saveSection
    // picking whichever came first in the DOM.
    select.dataset.tip = source.tip;

    // The escape hatch's own value. A NUL can't collide with a real option, so no list this
    // endpoint returns can ever shadow it.
    const TYPE_IT = "\u0000type-it";

    const back = document.createElement("button");
    back.type = "button";
    back.className = "field-toggle-btn";
    back.textContent = `back to ${source.label}`;
    back.dataset.tip = "Go back to picking from the list.";
    back.setAttribute("data-tip-right", "");
    back.hidden = true;

    const note = document.createElement("p");
    note.className = "field-lookup-note";
    note.hidden = true;

    const row = document.createElement("div");
    row.className = "field-lookup-row";
    row.append(select, input, back);
    wrap.append(row, note);

    let loaded = null;

    function say(message, isError) {
      note.textContent = message || "";
      note.hidden = !message;
      note.classList.toggle("field-lookup-error", !!isError);
    }

    // The box, for a value that isn't in the list - or because there is no list to be had.
    function showBox(message, isError) {
      select.hidden = true;
      input.hidden = false;
      back.hidden = !loaded;
      say(message, isError);
    }

    function showList() {
      select.hidden = false;
      input.hidden = true;
      back.hidden = true;
      say("", false);
    }

    function populate(options) {
      select.textContent = "";
      const current = (input.value || "").trim();

      // Whatever is saved goes in the list even when the server didn't return it - a location that
      // has since been retired, say. Without this, opening the dropdown would quietly land on
      // another value and a later save would keep it.
      const values = options.map(option => option.value);
      const entries = values.includes(current) || current === ""
        ? options
        : [{ value: current, label: `${current} (not listed)` }, ...options];

      for (const option of entries) {
        const opt = document.createElement("option");
        opt.value = option.value;
        opt.textContent = option.label || option.value;
        select.appendChild(opt);
      }

      const typeIt = document.createElement("option");
      typeIt.value = TYPE_IT;
      typeIt.textContent = "type a name instead…";
      select.appendChild(typeIt);

      select.value = current;
    }

    select.addEventListener("change", () => {
      if (select.value === TYPE_IT) {
        showBox(source.typeItMessage, false);
        input.focus();
        input.select();
        return;
      }
      input.value = select.value;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });

    back.addEventListener("click", () => {
      populate(loaded || []);
      showList();
    });

    async function load() {
      say(`Reading ${source.label}…`, false);
      try {
        const response = await fetch(source.endpoint);
        const payload = await response.json().catch(() => null);
        if (!response.ok) {
          // The server's message is the useful one - it says what went wrong and what to do
          // instead, which "HTTP 502" does not.
          showBox((payload && payload.error) || `Couldn't list ${source.label} (HTTP ${response.status}).`, true);
          return;
        }
        const options = (payload && payload.options) || [];
        if (options.length === 0) {
          showBox(source.emptyMessage, false);
          return;
        }
        loaded = options;
        populate(options);
        showList();
      } catch {
        showBox(`Couldn't reach this server to list ${source.label}. Type the name instead.`, true);
      }
    }

    // Not fetched here: every section on this page is built up front, and the sections are
    // collapsed, so loading on build would fetch the list on every visit to Settings whether or
    // not anyone opens this section. renderSection runs these the first time its section is
    // opened instead.
    if (loaders) loaders.push(load);
    else load();

    return wrap;
  }

  // Must stay identical to SettingsSecrets.Mask on the server: a saved secret is sent out as
  // this, and a save that sends it back untouched means "keep what's stored".
  const SECRET_MASK = "••••••••";

  const SECTION_TIPS = {
    media: "Adds a MOVIES tab: your own movies and TV shows, scanned from folders on the server, with artwork and descriptions from TMDB, playable here and in every app.",
    music: "Adds a MUSIC tab: your own music from folders on the server or another computer, with cover art, lyrics, playlists, radio and stats, played here and in every app. The library folders are set up at the bottom of this section.",
    mediaDownloads: "The + add button on Movies and Music: search your torrent sites through Prowlarr and download with qBittorrent, behind a VPN.",
    podcasts: "Adds a PODCASTS tab: shows the server follows, downloads and keeps, with Up Next, transcripts, bookmarks and clips that follow each person to every device.",
    email: "The mail account ReelHouse sends from - login alerts and notices about the download VPN.",
    loginAlerts: "Email you when someone enters the wrong password for ReelHouse.",
    logging: "How much detail the server writes to its own log. Applies immediately.",
    server: "The address and port ReelHouse listens on. Takes effect on restart.",
    internetExposed: "A second, dedicated port for reaching ReelHouse from outside your home network (e.g. through a Cloudflare Tunnel) - always requires login and HTTPS, regardless of the LOGIN setting."
  };

  // INTERNET EXPOSED MODE configures the server's own Kestrel binding and so isn't part of the
  // bulk /api/settings snapshot. It comes from SettingsSchema.cs like everything else, carrying
  // `dataEndpoint` to say where its values are fetched from - handled generically below, so no
  // client needs to know which section is the odd one.

  function buildField(field, value, loaders) {
    const row = document.createElement("div");
    // A lookup or a dropdown-backed field spans the grid whatever its type: both grow a second
    // line underneath (candidates, or a note about why there's no list), unreadable in a column.
    const wide = WIDE_TYPES.has(field.type) || !!field.lookup || !!field.optionsSource;
    row.className = "field-row" + (wide ? " field-row-wide" : "");
    // The tip lives on the row because <input> can't render the ::after pseudo-element.
    if (field.tip) row.dataset.tip = field.tip;

    if (field.type === "checkbox") {
      row.classList.add("field-checkbox-row");
      const label = document.createElement("label");
      label.className = "switch";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = !!value;
      input.dataset.field = field.name;
      const track = document.createElement("span");
      track.className = "switch-track";
      label.append(input, track);
      const text = document.createElement("span");
      text.className = "field-label";
      text.textContent = field.label;
      row.append(label, text);
      return row;
    }

    const label = document.createElement("label");
    label.className = "field-label";
    label.textContent = field.label;
    row.appendChild(label);

    if (field.type === "password") {
      const wrap = document.createElement("div");
      wrap.className = "field-password-row";
      const input = document.createElement("input");
      input.type = "password";
      input.className = "field-input";
      input.value = value ?? "";
      input.dataset.field = field.name;
      input.autocomplete = "off";
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "field-toggle-btn";
      toggle.setAttribute("data-tip-right", "");

      // A saved secret arrives as SettingsSecrets.Mask and the real value never leaves the
      // server, so while the box still holds the mask the browser has nothing to reveal - a
      // "show" button here swapped eight bullets for eight bullets and read as broken. In that
      // state the box is read-only and the button offers "replace" instead; only once the value
      // is something typed in this session does it become the show/hide toggle. Read-only also
      // stops a click-and-type from producing "••••••••newkey" and saving that as the secret.
      const masked = input.value === SECRET_MASK;
      input.readOnly = masked;

      function syncToggle() {
        if (input.readOnly) {
          toggle.textContent = "replace";
          toggle.dataset.tip = "This secret is saved on the server and never sent back here, so it can't be shown. Click to type a new one - leave it alone to keep what's stored.";
          return;
        }
        toggle.textContent = input.type === "password" ? "show" : "hide";
        toggle.dataset.tip = "Reveal what's typed here so you can check it.";
      }

      toggle.addEventListener("click", () => {
        if (input.readOnly) {
          input.readOnly = false;
          input.value = "";
          input.type = "text";
          input.focus();
        } else {
          input.type = input.type === "password" ? "text" : "password";
        }
        syncToggle();
      });

      // Backing out of a replace: an empty box would save as "clear this secret", so if the
      // field started masked and is left empty, put the mask back rather than letting a change
      // of mind wipe a working key.
      if (masked) {
        input.addEventListener("blur", () => {
          if (input.readOnly || input.value !== "") return;
          input.value = SECRET_MASK;
          input.type = "password";
          input.readOnly = true;
          syncToggle();
        });
      }

      syncToggle();
      wrap.append(input, toggle);
      row.appendChild(wrap);
      return row;
    }

    if (field.type === "csv") {
      const input = document.createElement("input");
      input.type = "text";
      input.className = "field-input";
      input.value = Array.isArray(value) ? value.join(", ") : "";
      input.dataset.field = field.name;
      row.appendChild(input);
      return row;
    }

    if (field.type === "select") {
      const select = document.createElement("select");
      select.className = "field-input";
      select.dataset.field = field.name;
      for (const option of field.options) {
        const opt = document.createElement("option");
        opt.value = option.value;
        opt.textContent = option.label;
        if (option.value === value) opt.selected = true;
        select.appendChild(opt);
      }
      row.appendChild(select);
      return row;
    }

    const input = document.createElement("input");
    input.type = field.type === "number" ? "number" : "text";
    input.className = "field-input";
    input.value = value ?? "";
    input.dataset.field = field.name;
    if (field.type === "number") {
      if (field.min !== undefined) input.min = field.min;
      if (field.max !== undefined) input.max = field.max;
      // A whole-number field steps by 1 rather than "any", so the spinner arrows land on legal
      // values and the browser's own red outline appears on 3.7 in a port box without waiting for
      // save. Fields with no declared step that aren't integers stay on "any".
      input.step = field.step !== undefined ? field.step : (field.integer ? 1 : "any");
    }
    if (field.lookup) row.appendChild(buildLookup(field, input));
    else if (field.optionsSource) row.appendChild(buildOptionsSource(field, input, loaders));
    else row.appendChild(input);

    // What to put in the box, for the fields where the tip explains what the number does without
    // ever answering it. Clickable, because reading a number and then typing it is a silly thing
    // to make someone do.
    if (field.recommended !== undefined && field.recommended !== null) {
      const hint = document.createElement("button");
      hint.type = "button";
      hint.className = "field-recommended";
      hint.textContent = `use recommended: ${field.recommended}`;
      hint.dataset.tip = "Set this field to the value we suggest for a typical install.";
      hint.addEventListener("click", () => {
        input.value = field.recommended;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      row.appendChild(hint);
    }

    return row;
  }

  // Which of the hand-written sections belong in basic mode. The schema sections carry
  // their own `basic` flag; these don't have a schema, so they're listed here instead.
  const BASIC_CUSTOM_SECTIONS = new Set(["LOGIN", "HTTPS", "RESTART", "LICENSE"]);

  // Which heading each hand-written section sits under. The schema sections carry `group` and
  // `groupOrder` from the server; these are rendered by hand here and so have to say for
  // themselves. Keep the names character-for-character identical to SettingsGroups in
  // SettingsSchema.cs - a typo doesn't error, it silently opens a second heading with the same
  // name next to the real one.
  const CUSTOM_SECTION_GROUPS = {
    "LOGIN": "Access & Network",
    "HTTPS": "Access & Network",
    "RESTART": "Maintenance",
    "LICENSE": "Notifications"
  };

  // Advanced is opt-in and remembered per device, so the owner can run advanced on a desktop
  // while someone else's phone stays simple. Purely a display preference - nothing here is
  // security-relevant, and every setting is still reachable either way.
  const ADVANCED_MODE_KEY = "reelhouse.settings.advanced";

  function isAdvancedMode() {
    try {
      return localStorage.getItem(ADVANCED_MODE_KEY) === "true";
    } catch {
      // Private browsing and some locked-down setups throw on access rather than returning
      // null. Falling back to basic is the safe default.
      return false;
    }
  }

  function setAdvancedMode(advanced) {
    try {
      localStorage.setItem(ADVANCED_MODE_KEY, advanced ? "true" : "false");
    } catch {
      // Preference just won't persist; the toggle still works for this visit.
    }
  }

  // The current contents of the search box, lowercased. Kept here rather than read from the DOM
  // inside applyMode so the advanced-mode toggle and the search box run through one filter.
  let searchQuery = "";

  // Both filters at once, because they interact: a search has to be able to reach an advanced
  // section while the page is in basic mode, or searching for "logging" in basic mode finds
  // nothing and looks broken. So a non-empty search overrides the mode filter entirely - if you typed the
  // word, you want the section, whichever mode you happen to be in.
  function applyMode(advanced) {
    const root = document.getElementById("settings-root");
    const searching = searchQuery.length > 0;

    for (const section of root.querySelectorAll(".settings-section")) {
      const matchesSearch = !searching || (section.dataset.search || "").includes(searchQuery);
      const allowedByMode = advanced || section.dataset.basic === "true";
      section.classList.toggle("hidden", searching ? !matchesSearch : !allowedByMode);
    }

    // A heading with nothing under it reads as a section that failed to load, which matters most
    // while searching - that's when most groups are empty.
    let visibleCount = 0;
    for (const group of root.querySelectorAll(".settings-group")) {
      const anyVisible = [...group.querySelectorAll(".settings-section")]
        .some(section => !section.classList.contains("hidden"));
      group.classList.toggle("hidden", !anyVisible);
      if (anyVisible) visibleCount++;
    }

    const empty = document.getElementById("settings-no-matches");
    if (empty) empty.classList.toggle("hidden", visibleCount > 0);

    // Every section starts collapsed, including the first one - a section that is always open
    // reads as stuck rather than as a helpful starting point.

    const label = document.getElementById("mode-label");
    if (label) label.textContent = advanced ? "advanced" : "basic";

    // The MutationObserver in app.js only watches childList, so a class-only change like this
    // won't reposition tooltips on its own.
    window.ReelHouseTooltips.schedule();
  }

  // Groups the rendered sections under their headings, in the order the server put the groups in
  // (groupOrder). Sections keep their relative order within a group, which is the order they're
  // declared in SettingsSchema.Sections - the descriptions lean on it, so it isn't ours to
  // re-sort.
  function groupSections(entries) {
    const groups = new Map();
    for (const entry of entries) {
      const name = entry.group || "Other";
      if (!groups.has(name)) groups.set(name, { name, order: entry.groupOrder, sections: [] });
      const group = groups.get(name);
      // A group's position is the lowest any of its sections claims. Hand-written sections carry
      // no groupOrder at all, so without this a group whose first entry is one of them would sort
      // to the end regardless of where the server puts it.
      if (entry.groupOrder != null && (group.order == null || entry.groupOrder < group.order)) {
        group.order = entry.groupOrder;
      }
      group.sections.push(entry.element);
    }

    const fragment = document.createDocumentFragment();
    const ordered = [...groups.values()].sort((a, b) =>
      (a.order ?? Number.MAX_SAFE_INTEGER) - (b.order ?? Number.MAX_SAFE_INTEGER));

    for (const group of ordered) {
      const wrap = document.createElement("div");
      wrap.className = "settings-group";

      const heading = document.createElement("h2");
      heading.className = "settings-group-heading";
      heading.textContent = group.name;
      wrap.appendChild(heading);

      for (const section of group.sections) wrap.appendChild(section);
      fragment.appendChild(wrap);
    }
    return fragment;
  }

  // Real text rather than a tooltip: the per-field tips are hover-only by design (so a tap
  // doesn't leave one stuck open), which means they're invisible on a phone. This paragraph is
  // what actually orients someone, on any device.
  function buildSectionIntro(text) {
    const intro = document.createElement("p");
    intro.className = "settings-hint settings-section-intro";
    intro.textContent = text;
    return intro;
  }

  function renderSection(schema, data) {
    const section = document.createElement("div");
    section.className = "settings-section";
    if (schema.basic) section.dataset.basic = "true";
    if (schema.group) section.dataset.group = schema.group;
    if (typeof schema.groupOrder === "number") section.dataset.groupOrder = schema.groupOrder;

    // What the search box matches against. The field tips are included deliberately: they're the
    // only place a setting is described in the words someone would actually search for - nobody
    // types "qbittorrentUrl", they type "torrent".
    section.dataset.search = [
      schema.title,
      schema.description,
      ...schema.fields.flatMap(f => [f.label, f.tip])
    ].join(" ").toLowerCase();

    const header = document.createElement("div");
    header.className = "settings-section-header";
    header.innerHTML = `<span class="settings-section-title">${schema.title}</span><span class="settings-section-caret">&#9656;</span>`;
    if (SECTION_TIPS[schema.key]) header.dataset.tip = SECTION_TIPS[schema.key];
    // Anything a field wants fetched from the server, deferred until this section is first
    // opened - see buildOptionsSource. Every section on this page is built up front, so doing it
    // any earlier would mean fetching those lists on every visit to Settings.
    const loaders = [];

    header.addEventListener("click", () => {
      section.classList.toggle("open");
      if (section.classList.contains("open") && loaders.length > 0) {
        for (const load of loaders.splice(0)) load();
      }
      window.ReelHouseTooltips.schedule();
    });

    const body = document.createElement("div");
    body.className = "settings-section-body";

    if (schema.description) body.appendChild(buildSectionIntro(schema.description));

    const grid = document.createElement("div");
    grid.className = "field-grid";
    for (const field of schema.fields) {
      grid.appendChild(buildField(field, readPath(data, field.name), loaders));
    }
    body.appendChild(grid);

    // The field above says where the server should listen, which is not what someone typing an
    // address into the phone app needs to know. The server is the
    // only side that can see what addresses this machine actually has, so it gets asked.
    if (schema.key === "server") body.appendChild(buildLocalAddressPanel(loaders));

    // MUSIC and PODCASTS each grow a hand-built part under their fields (audio-extras.js): the
    // music library folders and ListenBrainz, and the podcast download folder's picker, storage
    // and OPML. Fetched when the section is first opened, like the other loaders.
    if (schema.key === "music" && window.ReelHouseAudioExtras) window.ReelHouseAudioExtras.musicSettingsPanel(body, body, loaders);
    if (schema.key === "podcasts" && window.ReelHouseAudioExtras) window.ReelHouseAudioExtras.podcastsSettingsPanel(body, body, loaders);

    const needsRestart = schema.fields.some(f => f.requiresRestart);

    const footer = document.createElement("div");
    footer.className = "settings-section-footer";
    const saveBtn = document.createElement("button");
    saveBtn.className = "btn";
    saveBtn.textContent = "save";
    saveBtn.dataset.tip = needsRestart
      ? "Save this section. Fields here only take effect after a restart - use the restart button once saved."
      : "Save this section. Changes take effect immediately - no restart needed.";
    const errors = document.createElement("ul");
    errors.className = "field-errors";
    footer.append(saveBtn);
    if (schema.extraAction) {
      // Pure data from the schema - an endpoint to POST to - so the same definition works for
      // every client. What comes back is shown rather than thrown away: the test email reports
      // whether the mail server actually accepted it, and that answer is the entire point of
      // pressing the button. Only an action that says reloadAfter gets a reload.
      const actionBtn = document.createElement("button");
      actionBtn.className = "btn";
      actionBtn.textContent = schema.extraAction.label;
      if (schema.extraAction.tip) actionBtn.dataset.tip = schema.extraAction.tip;
      actionBtn.addEventListener("click", async () => {
        const original = actionBtn.textContent;
        actionBtn.disabled = true;
        actionBtn.textContent = "working…";
        showFieldErrors(errors, []);
        try {
          const response = await fetch(schema.extraAction.endpoint, {
            method: schema.extraAction.method || "POST"
          });
          // Endpoints that answer with no body at all are legal - "did it work" is the status.
          const payload = await response.json().catch(() => ({}));

          if (!response.ok) {
            const message = payload.error || `That didn't work (${response.status}).`;
            showFieldErrors(errors, [message]);
            showToast(message, false);
            return;
          }

          if (schema.extraAction.reloadAfter) {
            window.location.reload();
            return;
          }
          showToast(payload.detail || payload.message || "Done.", true);
        } catch {
          const message = "Could not reach the server.";
          showFieldErrors(errors, [message]);
          showToast(message, false);
        } finally {
          actionBtn.disabled = false;
          actionBtn.textContent = original;
        }
      });
      footer.append(actionBtn);
    }
    if (needsRestart) {
      footer.append(buildRestartButton(schema.restartService || "server"));
    }
    footer.append(errors);
    body.appendChild(footer);

    saveBtn.addEventListener("click", () => saveSection(schema, section, errors, saveBtn));

    section.append(header, body);
    return section;
  }

  function buildLocalAddressPanel(loaders) {
    const panel = document.createElement("div");
    panel.className = "local-address";

    const status = document.createElement("div");
    status.className = "local-address-status";
    status.textContent = "checking\u2026";

    const list = document.createElement("ul");
    list.className = "local-address-list";

    const note = document.createElement("p");
    note.className = "settings-hint local-address-note";
    note.hidden = true;

    panel.append(status, list, note);

    // Interface names come from the operating system, and the addresses are assembled by the
    // server, so every one of these goes in as text rather than markup.
    function buildRow(entry) {
      const row = document.createElement("li");

      const url = document.createElement("code");
      url.className = "local-address-url";
      url.textContent = entry.url;

      const label = document.createElement("span");
      label.className = "local-address-interface";
      label.textContent = entry.looksVirtual ? `${entry.interface} (virtual adapter)` : entry.interface;

      const copyBtn = document.createElement("button");
      copyBtn.type = "button";
      copyBtn.className = "btn";
      copyBtn.textContent = "copy";
      copyBtn.dataset.tip = "Copy this address to paste into the phone app or a browser.";
      copyBtn.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(entry.url);
          showToast("Address copied", true);
        } catch {
          // Browsers refuse clipboard access on plain HTTP, which is exactly how a LAN server
          // is usually reached - so select the text for a manual copy instead.
          const range = document.createRange();
          range.selectNodeContents(url);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          showToast("Couldn't copy automatically - the address is selected, press Ctrl+C", false);
        }
      });

      row.append(url, label, copyBtn);
      return row;
    }

    function render(payload) {
      const addresses = payload.addresses || [];
      list.replaceChildren(...addresses.map(buildRow));

      if (addresses.length === 0) {
        status.dataset.state = "none";
        status.textContent = "This machine has no network address at the moment, so nothing else on your network can reach it.";
        note.hidden = true;
        return;
      }

      // First in the list is the plain LAN address on a real adapter, if there is one - the
      // server sorts them that way, so this line can just take the head of it.
      const primary = addresses[0];
      status.dataset.state = "ok";
      status.textContent = `This computer is ${payload.hostName} at ${primary.address} - apps and browsers on your network reach it at ${primary.url}.`;

      note.hidden = false;
      note.textContent =
        `Most devices can use ${payload.scheme}://${payload.hostName}.local:${payload.port} instead, which is easier to remember and keeps working if the address changes. ` +
        "That address comes from your router, so it can be a different one after a power cut - give this machine a fixed (reserved) address there if you'd rather it never moved.";
    }

    async function probe() {
      try {
        const response = await fetch("/api/system/addresses");
        if (!response.ok) {
          status.dataset.state = "none";
          status.textContent = "Could not ask the server for its address.";
          return;
        }
        render(await response.json());
      } catch {
        status.dataset.state = "none";
        status.textContent = "Could not reach the server.";
      }
    }

    loaders.push(probe);
    return panel;
  }

  // Sections whose fields only bind at startup get this next to save. There is one process, so
  // the service name is only passed through. The server refuses (409) when nothing supervises the
  // process, and that refusal is shown as-is: it explains the situation better than a generic
  // message would.
  function buildRestartButton(service) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn";
    btn.textContent = "restart server";
    btn.dataset.tip = "Restart ReelHouse so saved restart-required settings take effect. Playback stops and the page is unreachable for a few seconds; running as a service, it comes back on its own.";
    btn.addEventListener("click", async () => {
      if (!confirm("Restart ReelHouse now? It will be unavailable for a few seconds, and anything playing stops.")) return;
      btn.disabled = true;
      try {
        const response = await fetch("/api/system/restart", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ service: service || "server" })
        });
        const payload = await response.json().catch(() => ({}));
        if (response.status === 202) {
          showToast("Restarting ReelHouse - back in a few seconds", true);
        } else {
          showToast(payload.error || "Could not restart ReelHouse.", false);
        }
      } catch {
        showToast("Could not reach the server to restart it.", false);
      } finally {
        btn.disabled = false;
      }
    });
    return btn;
  }

  // What is wrong with what's in a number box, or null if nothing is. Returns the message a user
  // should read rather than a boolean, so the caller can list several at once the way a failed
  // save from the server already does.
  //
  // The empty-string check is doing more work than it looks. A number input whose contents aren't
  // a parseable number - "abc", "1.2.3", a lone "-" - reports value as "" and not as what was
  // typed, so garbage and a genuinely blank box are indistinguishable from .value alone.
  // validity.badInput is what separates the two cases, and both are refused rather than one of
  // them being quietly rounded to zero.
  function numberProblem(field, input) {
    const label = field.label || field.name;

    if (input.validity && input.validity.badInput) return `${label} must be a number.`;
    if (input.value.trim() === "") return `${label} must be a number.`;

    const value = Number(input.value);
    if (!Number.isFinite(value)) return `${label} must be a number.`;

    if (field.integer && !Number.isInteger(value)) return `${label} must be a whole number.`;

    const min = field.min;
    const max = field.max;
    if (typeof min === "number" && typeof max === "number" && (value < min || value > max)) {
      return `${label} must be between ${min} and ${max}.`;
    }
    if (typeof min === "number" && value < min) return `${label} must be ${min} or more.`;
    if (typeof max === "number" && value > max) return `${label} must be ${max} or less.`;

    return null;
  }

  async function saveSection(schema, section, errorsEl, saveBtn) {
    const data = {};
    const problems = [];
    for (const field of schema.fields) {
      const input = section.querySelector(`[data-field="${field.name}"]`);
      if (!input) continue;
      let value;
      if (field.type === "checkbox") value = input.checked;
      else if (field.type === "number") {
        const problem = numberProblem(field, input);
        if (problem) {
          problems.push(problem);
          continue;
        }
        value = Number(input.value);
      }
      else if (field.type === "csv") value = input.value.split(",").map(s => s.trim()).filter(s => s.length > 0);
      else value = input.value;
      writePath(data, field.name, value);
    }

    // Caught here rather than left to the server so the message names the box to go and fix, and
    // so a value the server would reject never leaves the page. The server validates all of this
    // again regardless - see SaveSectionAsync - since a client is free to skip these checks.
    if (problems.length > 0) {
      showFieldErrors(errorsEl, problems);
      showToast(`${schema.title}: not saved`, false);
      return;
    }

    await submit(schema.endpoint, data, schema.title, errorsEl, saveBtn);
  }

  // A hand-built section, shaped like a schema one: header that opens and closes it, intro
  // paragraph, body. Used by LOGIN, HTTPS and RESTART below.
  function buildCustomSection(title, tip, intro) {
    const section = document.createElement("div");
    section.className = "settings-section";

    const header = document.createElement("div");
    header.className = "settings-section-header";
    header.innerHTML = `<span class="settings-section-title">${escapeHtml(title)}</span><span class="settings-section-caret">&#9656;</span>`;
    header.dataset.tip = tip;
    const opened = [];
    header.addEventListener("click", () => {
      section.classList.toggle("open");
      if (section.classList.contains("open")) for (const run of opened.splice(0)) run();
      window.ReelHouseTooltips.schedule();
    });

    const body = document.createElement("div");
    body.className = "settings-section-body";
    if (intro) body.appendChild(buildSectionIntro(intro));

    section.append(header, body);
    return { section, body, onFirstOpen: (run) => opened.push(run) };
  }

  // Sign-in on or off. Changing a password or adding people is on the ACCOUNTS tab, which only
  // exists while sign-in is on.
  function renderAuthSection() {
    const { section, body } = buildCustomSection(
      "LOGIN",
      "Require a username and password to open ReelHouse. Anyone who can reach this server can otherwise use it freely.",
      "Requires a username and password to open ReelHouse, here and in the apps. Turn it off only on a home network you trust, and never while this server can be reached from anywhere else. Passwords and other people's accounts are managed on the ACCOUNTS tab.");

    const status = document.createElement("div");
    status.className = "settings-hint";
    status.textContent = "checking login status…";
    body.appendChild(status);

    const formWrap = document.createElement("div");
    body.appendChild(formWrap);

    const errors = document.createElement("ul");
    errors.className = "field-errors";
    body.appendChild(errors);

    // Only reachable with login off and no account at all - the first admin is normally created
    // by the sign-in box on first visit, so this is the rare install that started with it off.
    function renderCreateForm() {
      formWrap.innerHTML = `
        <div class="field-row field-row-wide">
          <label class="field-label" for="auth-new-username">Username</label>
          <input type="text" class="field-input" id="auth-new-username" autocomplete="username" />
        </div>
        <div class="field-row field-row-wide">
          <label class="field-label" for="auth-new-password">Password</label>
          <input type="password" class="field-input" id="auth-new-password" autocomplete="new-password" />
        </div>
        <div class="field-row field-row-wide">
          <label class="field-label" for="auth-new-confirm">Confirm Password</label>
          <input type="password" class="field-input" id="auth-new-confirm" autocomplete="new-password" />
        </div>
        <div class="settings-section-footer"><button class="btn" id="auth-enable-btn">create admin and require login</button></div>`;

      document.getElementById("auth-enable-btn").addEventListener("click", async () => {
        errors.innerHTML = "";
        const username = document.getElementById("auth-new-username").value.trim();
        const password = document.getElementById("auth-new-password").value;
        if (password !== document.getElementById("auth-new-confirm").value) {
          showFieldErrors(errors, ["Passwords do not match."]);
          return;
        }
        await enable({ username, password });
      });
    }

    function renderTurnOn() {
      formWrap.innerHTML = `<div class="settings-section-footer"><button class="btn" id="auth-enable-btn">require login</button></div>`;
      document.getElementById("auth-enable-btn").addEventListener("click", () => enable({ username: "", password: "" }));
    }

    function renderTurnOff() {
      formWrap.innerHTML = `<div class="settings-section-footer"><button class="btn" id="auth-disable-btn">turn off login</button></div>`;
      document.getElementById("auth-disable-btn").addEventListener("click", async () => {
        if (!confirm("Turn off login? Anyone who can reach this server will then have full access to ReelHouse, including Settings.")) return;
        try {
          const response = await fetch("/api/auth/disable", { method: "POST" });
          if (!response.ok) {
            showToast("Could not turn off login", false);
            return;
          }
          showToast("Login turned off", true);
          window.location.reload();
        } catch {
          showFieldErrors(errors, ["Network error while saving."]);
        }
      });
    }

    async function enable(credentials) {
      errors.innerHTML = "";
      try {
        const response = await fetch("/api/auth/enable", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(credentials)
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) {
          showFieldErrors(errors, payload.errors || [payload.error || "Could not turn on login."]);
          showToast("Login not turned on", false);
          return;
        }
        showToast("Login required", true);
        // The tabs, the logout button and the accounts tab all depend on it - start again.
        window.location.reload();
      } catch {
        showFieldErrors(errors, ["Network error while saving."]);
      }
    }

    async function refreshStatus() {
      errors.innerHTML = "";
      try {
        const response = await fetch("/api/auth/status");
        const payload = await response.json();
        if (payload.enabled) {
          status.textContent = `login is required to open ReelHouse${payload.username ? ` - you are signed in as ${payload.username}` : ""}.`;
          renderTurnOff();
        } else if (payload.configured) {
          status.textContent = "no login required - open to anyone who can reach this server. Turning it on again keeps every existing account.";
          renderTurnOn();
        } else {
          status.textContent = "no login required, and no account exists yet. Create the admin account to turn it on.";
          renderCreateForm();
        }
      } catch {
        status.textContent = "could not check login status.";
      }
    }

    refreshStatus();
    return section;
  }

  // The server makes its own certificate authority on first start and signs its HTTPS
  // certificate with it, so a browser warns until the authority is trusted on that device. The
  // authority's certificate is public (GET /api/certificate-authority); whether there is one to
  // hand out is asked with HEAD, so an install on a real certificate shows no download link.
  function renderHttpsSection() {
    const { section, body, onFirstOpen } = buildCustomSection(
      "HTTPS",
      "Trust this server's own certificate on a device, so its HTTPS address opens without a warning.",
      "ReelHouse answers on HTTPS as well as plain HTTP, using a certificate it made for itself. Browsers and the apps warn about that certificate until the authority that signed it is trusted on the device - do this once per phone, tablet or computer.");

    const steps = document.createElement("div");
    steps.className = "settings-hint";
    steps.textContent = "checking…";
    body.appendChild(steps);

    onFirstOpen(async () => {
      // HTTPS switched off means there is no authority to ask about - checking first saves a
      // 404 from the HEAD below. The addresses endpoint knows, because it builds https:// URLs
      // only when HTTPS actually came up.
      let httpsOn = true;
      try {
        const response = await fetch("/api/system/addresses");
        if (response.ok) httpsOn = (await response.json()).scheme === "https";
      } catch {
        // Unknown: ask about the certificate anyway.
      }
      if (!httpsOn) {
        steps.textContent = "HTTPS is switched off on this server, so there is no certificate to trust. It is on by default; Https:Enabled in the server's settings or on its command line turns it back on.";
        return;
      }

      let available = false;
      try {
        available = (await fetch("/api/certificate-authority", { method: "HEAD", cache: "no-store" })).ok;
      } catch {
        available = false;
      }
      if (!available) {
        steps.textContent = "This server isn't using a certificate it made itself (or HTTPS is off), so there is nothing to download here. If its HTTPS address still shows a warning, the certificate it was given is the one to look at.";
        return;
      }
      steps.innerHTML = `
        <p><a class="btn" href="/api/certificate-authority" download="reelhouse-ca.crt">download the certificate</a></p>
        <p>Then trust it on the device you downloaded it to:</p>
        <ul class="https-trust-steps">
          <li><b>Mac:</b> open the file, add it to the System keychain, then double-click it in Keychain Access and set <i>When using this certificate</i> to <i>Always Trust</i>.</li>
          <li><b>Windows:</b> open the file, choose <i>Install Certificate</i>, <i>Local Machine</i>, and place it in <i>Trusted Root Certification Authorities</i>.</li>
          <li><b>iPhone and iPad:</b> install the downloaded profile in Settings, then turn it on under <i>General → About → Certificate Trust Settings</i>.</li>
          <li><b>Android:</b> install it as a CA certificate (Settings → Security → Encryption &amp; credentials).</li>
          <li><b>Linux:</b> import it in the browser under Settings → Privacy and security → Security → Manage certificates → Authorities.</li>
        </ul>
        <p>Restart the browser afterwards. The certificate only proves this server is the one you installed - it can't be used to read anyone else's traffic.</p>`;
    });

    return section;
  }

  // The same restart the restart-required sections offer next to save, for when nothing was
  // changed here - after replacing a file on disk, say.
  // The ReelHouse license: shows who it's issued to, and takes a new .lic file. What it unlocks is
  // the ReelHouse push service (PUSH NOTIFICATIONS) - nothing else in ReelHouse depends on it.
  function renderLicenseSection() {
    const { section, body } = buildCustomSection(
      "LICENSE",
      "The ReelHouse license this server uses for the ReelHouse push service.",
      "Your ReelHouse license, the .lic file you were sent when you bought ReelHouse. It's what lets this server send notifications to the ReelHouse apps through the ReelHouse push service (PUSH NOTIFICATIONS). Everything else works without one.");

    const status = document.createElement("div");
    status.className = "settings-hint";
    status.textContent = "checking license…";
    body.appendChild(status);

    const errors = document.createElement("ul");
    errors.className = "field-errors";

    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".lic,application/json,text/plain";
    input.style.display = "none";

    const button = document.createElement("button");
    button.className = "btn";
    button.textContent = "install license file";
    button.dataset.tip = "Pick the .lic file. It's checked before anything is saved, so a wrong file never replaces a license that works.";
    button.addEventListener("click", () => input.click());

    async function refresh() {
      try {
        const response = await fetch("/api/license/status");
        const payload = await response.json();
        status.textContent = payload.valid
          ? `Licensed to ${payload.customerName}. The ReelHouse push service is available.`
          : "No ReelHouse license installed. Notifications through the ReelHouse push service need one.";
      } catch {
        status.textContent = "Could not check the license.";
      }
    }

    input.addEventListener("change", async () => {
      const file = input.files && input.files[0];
      input.value = "";
      if (!file) return;
      showFieldErrors(errors, []);
      try {
        const response = await fetch("/api/license/install", {
          method: "POST",
          headers: { "Content-Type": "text/plain" },
          body: await file.text()
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) {
          const message = payload.error || `That didn't work (${response.status}).`;
          showFieldErrors(errors, [message]);
          showToast(message, false);
          return;
        }
        showToast(`License installed for ${payload.customerName}`, true);
        await refresh();
      } catch {
        showFieldErrors(errors, ["Could not reach the server."]);
      }
    });

    const footer = document.createElement("div");
    footer.className = "settings-section-footer";
    footer.append(button, input, errors);
    body.appendChild(footer);
    refresh();
    return section;
  }

  function renderRestartSection() {
    const { section, body } = buildCustomSection(
      "RESTART",
      "Restart the ReelHouse server.",
      "Restarts the server. Anything playing stops and the page is unreachable for a few seconds; when ReelHouse runs as a service, it comes back on its own.");
    const footer = document.createElement("div");
    footer.className = "settings-section-footer";
    footer.appendChild(buildRestartButton("server"));
    body.appendChild(footer);
    return section;
  }

  async function submit(endpoint, body, label, errorsEl, saveBtn) {
    errorsEl.innerHTML = "";
    saveBtn.disabled = true;
    const originalText = saveBtn.textContent;
    saveBtn.textContent = "saving...";
    try {
      const response = await fetch(endpoint, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        showFieldErrors(errorsEl, payload.errors || ["Save failed."]);
        showToast(`${label}: not saved`, false);
      } else {
        showToast(`${label} saved`, true);
        // Saved, but with something to fix (a push key file that isn't there yet).
        if (Array.isArray(payload.warnings) && payload.warnings.length > 0) showFieldErrors(errorsEl, payload.warnings);
        // The Movies tab only exists while the section is on - show or hide it now.
        if (endpoint === "/api/settings/media") window.ReelHouseAuth.checkMovies();
        // Same for the Music and Podcasts tabs.
        if ((endpoint === "/api/settings/music" || endpoint === "/api/settings/podcasts") && window.ReelHouseAudio) window.ReelHouseAudio.checkEnabled();
      }
    } catch {
      showFieldErrors(errorsEl, ["Network error while saving."]);
      showToast("Save failed", false);
    } finally {
      saveBtn.disabled = false;
      saveBtn.textContent = originalText;
    }
  }

  function showFieldErrors(el, errors) {
    el.innerHTML = "";
    for (const message of errors) {
      const li = document.createElement("li");
      li.textContent = message;
      el.appendChild(li);
    }
  }

  let toastTimeout;
  function showToast(message, success) {
    const toast = document.getElementById("toast");
    clearTimeout(toastTimeout);
    toast.textContent = message;
    toast.className = "toast " + (success ? "success" : "error");
    toastTimeout = setTimeout(() => { toast.className = "toast hidden"; }, 3000);
  }

  async function load() {
    const root = document.getElementById("settings-root");
    root.innerHTML = `<div class="empty-state">loading settings&hellip;</div>`;
    try {
      const [settingsResponse, schemaResponse] = await Promise.all([
        fetch("/api/settings"),
        fetch("/api/settings/schema")
      ]);
      if (!settingsResponse.ok) throw new Error(`HTTP ${settingsResponse.status}`);
      if (!schemaResponse.ok) throw new Error(`HTTP ${schemaResponse.status} loading the settings schema`);
      const data = await settingsResponse.json();
      const sections = await schemaResponse.json();

      root.innerHTML = "";

      // A section can say its values live somewhere other than the bulk snapshot (dataEndpoint).
      // Only INTERNET EXPOSED MODE does today; fetching them together keeps that from adding a
      // round trip per section if more ever do. A failed fetch yields null, which renders the
      // section with empty values rather than dropping it - the same thing an absent snapshot key
      // already does.
      const external = new Map();
      await Promise.all(sections.filter(s => s.dataEndpoint).map(async schema => {
        const value = await fetch(schema.dataEndpoint)
          .then(r => r.ok ? r.json() : null)
          .catch(() => null);
        external.set(schema.key, value);
      }));

      const entries = sections.map(schema => ({
        element: renderSection(schema, schema.dataEndpoint ? external.get(schema.key) : data[schema.key]),
        group: schema.group,
        groupOrder: schema.groupOrder
      }));

      // The hand-written sections: built the same way as before, then tagged with the group and
      // basic flag the schema would have carried for them.
      for (const element of [
        renderAuthSection(),
        renderHttpsSection(),
        renderLicenseSection(),
        renderRestartSection()
      ]) {
        const title = element.querySelector(".settings-section-title")?.textContent ?? "";
        if (BASIC_CUSTOM_SECTIONS.has(title)) element.dataset.basic = "true";
        // No schema to build a field list from, so the rendered text is what search matches on.
        // Good enough - these sections are short, and their words are on screen.
        element.dataset.search = element.textContent.toLowerCase();
        entries.push({ element, group: CUSTOM_SECTION_GROUPS[title] });
      }

      root.appendChild(groupSections(entries));

      const empty = document.createElement("div");
      empty.id = "settings-no-matches";
      empty.className = "empty-state hidden";
      empty.textContent = "no settings match that search.";
      root.appendChild(empty);

      const toggle = document.getElementById("advanced-mode-toggle");
      if (toggle) {
        toggle.checked = isAdvancedMode();
        toggle.onchange = () => {
          setAdvancedMode(toggle.checked);
          applyMode(toggle.checked);
        };
      }

      // Searching matches field labels and tips, not just section titles, so "vpn" finds the
      // download settings and "port" finds every section that binds one. Not persisted like the mode
      // toggle: a filter still applied on the next visit would be a page with settings missing.
      const search = document.getElementById("settings-search");
      if (search) {
        search.value = "";
        search.oninput = () => {
          searchQuery = search.value.trim().toLowerCase();
          applyMode(isAdvancedMode());
        };
      }

      applyMode(isAdvancedMode());
    } catch (err) {
      root.innerHTML = `<div class="empty-state">failed to load settings: ${err.message}</div>`;
    }
  }

  return { load };
})();
