using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReelHouse;

// The single description of what every settings section contains: which fields, what to call
// them, what to tell the user about them, and what values are legal. Served to every client from
// /api/settings/schema so the web dashboard, the iOS/macOS app, and the Android app all render
// the same forms from the same source instead of each hard-coding its own copy of 120 fields.
//
// This was previously the SECTIONS array inside wwwroot/settings.js, where only the browser
// could reach it. Moving it here is what makes "every setting manageable from every client"
// maintainable: adding a setting is one edit in this file plus its DTO, not four edits across
// four codebases that silently drift apart.
//
// Kept as plain data on purpose - no behaviour, no formatting, nothing platform-specific. A
// client decides for itself how a "number" field or a "select" should look; this only says what
// the field *is*. The one deliberate exception is ExtraAction, which is still pure data (an
// endpoint to POST to), not a callback.
//
// SettingsSchemaTests asserts this stays in exact correspondence with the DTOs in
// SettingsDtos.cs, so a field added to one and forgotten in the other fails the build rather
// than quietly becoming uneditable.

public sealed record SettingsFieldOption(string Value, string Label);

// An action a section offers beyond editing its fields - a button, in UI terms. Expressed as an
// endpoint and method rather than a callback so a client that can't or won't implement one can
// simply skip it.
public sealed record SettingsActionSchema(
    string Key,
    string Label,
    string Tip,
    string Endpoint,
    string Method)
{
    // Whether the client should reload the page after the action succeeds. Only "re-run setup
    // wizard" needs it - the wizard can't reappear without one - and the web dashboard used to
    // reload after every action because it was the only action there was. A test send has
    // something to say when it finishes, and reloading throws it away, so this is opt-in rather
    // than the default. Clients that don't have a page to reload (the phone and Mac apps) ignore
    // it entirely.
    public bool ReloadAfter { get; init; }
}

// A lookup a text field offers: type something into the field, press the button, and pick from
// what comes back to fill in *other* fields of the same section. Pure data like ExtraAction - an
// endpoint, not a callback - so this stays platform-neutral and a client that hasn't implemented
// it renders an ordinary text box, exactly as every client did before this existed.
//
// The endpoint takes ?query= and answers either
//   { "results": [ { "label": "Holland, Bell County, Texas", "values": { "latitude": 31.0932, "longitude": -97.4025 } } ] }
// or, for anything the user should be told about, an { "error": "..." } with a non-2xx status.
// Keys in "values" are field names in this same section; a client applies the ones it recognises
// and ignores the rest.
public sealed record SettingsLookupSchema(
    string Label,
    string Tip,
    string Endpoint);

// The other half of that idea, for a text field whose legal values are a list the server can go
// and find: OLLAMA's Model box, filled from the models actually pulled on the machine running
// Ollama, so nobody has to remember whether they pulled gemma3:4b or gemma3:4b-it-qat. Pure data
// again - an endpoint, not a callback - so this stays platform-neutral.
//
// The endpoint takes no parameters and answers either
//   { "options": [ { "value": "gemma3:4b", "label": "gemma3:4b - 3.3 GB" } ] }
// or, for anything the user should be told about, an { "error": "..." } with a non-2xx status.
// It is the same shape as a select's own options, on purpose: a client that can draw one can
// draw the other.
//
// Three rules a client has to keep, because they are what make this safe to attach to a field
// that was a free text box yesterday:
//   - Whatever the field is set to now must appear in the list even if the server didn't return
//     it, or opening the dropdown would silently change a working setting.
//   - There must still be a way to type a value that isn't listed. The list is what's installed
//     at this moment, and naming a model you are about to pull is a legitimate thing to do.
//   - If the fetch fails - Ollama down, older client, no route - fall back to the plain text box
//     and say why. That is exactly what every client did before this existed, so nothing is lost.
public sealed record SettingsOptionsSourceSchema(
    string Label,
    string Tip,
    string Endpoint,
    // What to show when the endpoint succeeds but the list is empty. Here rather than in the
    // client because it is the one message that has to name the thing the user should go and do
    // ("ollama pull ..."), and no client should have to know that.
    string EmptyMessage,
    // What to show once someone picks "type a name instead", for the same reason. This started as
    // one hardcoded line about Ollama tags in each of the three client renderers, which was
    // accurate while Ollama's model box was the only field using this - and silently wrong for
    // every field added afterwards. A model tag, a model id and a URL want different advice.
    string TypeItMessage);

public sealed record SettingsFieldSchema
{
    public required string Name { get; init; }
    public required string Label { get; init; }

    // One of: text, number, checkbox, password, select, csv. A client that meets a type it
    // doesn't recognise should render the field read-only rather than guessing - better to show
    // a value that can't be edited than to write back something malformed.
    public required string Type { get; init; }

    public required string Tip { get; init; }

    // Numeric bounds, mirroring the [Range] attributes on the DTO properties. Advisory only -
    // the server validates regardless, since a client is free to ignore these. Kept honest by
    // SettingsSchemaTests, which compares every one of these against its DTO's [Range]: bounds
    // that drifted would have clients rejecting values the server accepts, or vice versa.
    public double? Min { get; init; }
    public double? Max { get; init; }
    public double? Step { get; init; }

    // Whether a "number" field holds a whole number. Set from the DTO property type when Sections
    // is built rather than declared per field, for the same reason as Secret below: a hand-written
    // flag could disagree with the type the value actually binds to. Without it a client has no way
    // to tell a port (int) from a free-space threshold in GB (double) - both are plain numbers with
    // no step - and 3.7 typed into the port box would reach the server as a bind error rather than
    // as "Broker Port must be a whole number".
    public bool Integer { get; init; }

    // The value someone with no opinion should use, for the numeric settings where "what do I
    // even put here?" is the real question - a confidence threshold means nothing to somebody who
    // hasn't watched this particular camera misfire for a week. Clients show it next to the
    // control and can offer to jump back to it.
    //
    // This is a recommendation, not the shipped default, and the two differ on purpose: a setting
    // can ship off (0) because off is the safe way to arrive, while the number worth trying first
    // once you have a reason to touch it is something else entirely. Where they agree, saying so
    // is still useful - it tells the reader they have nothing to decide.
    public double? Recommended { get; init; }

    // Only for Type == "select".
    public IReadOnlyList<SettingsFieldOption>? Options { get; init; }

    // Only for Type == "text": an optional "look this up for me" button that fills in sibling
    // fields. Optional on every client - the field is still an editable text box without it.
    public SettingsLookupSchema? Lookup { get; init; }

    // Only for Type == "text": where to fetch the values this field is likely to hold, so the
    // client can offer a list to pick from instead of asking someone to type an exact model tag.
    // Optional on every client, and the field stays typeable either way - see
    // SettingsOptionsSourceSchema.
    public SettingsOptionsSourceSchema? OptionsSource { get; init; }

    // True for the handful of fields that bind a socket or otherwise only read their value at
    // startup. A client should tell the user the change won't apply until the server restarts.
    public bool RequiresRestart { get; init; }

    // Whether the stored value is a secret. Derived from Type rather than declared separately so
    // the two can't disagree: everything rendered as a password is masked on read and left alone
    // on write unless the client actually changed it.
    [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
    public bool Secret => Type == "password";
}

// The seven headings the settings page is divided into. This exists because the section list grew
// to 36 entries in build order, which meant the four trigger sections sat at positions 14, 17, 34
// and 35 and everything that depends on Email being configured was spread across four corners of
// the page. Grouping is deliberately a property of the schema rather than of any one client: the
// web dashboard draws these as headings between accordions, the phone and Mac apps as section
// headers in their list, and neither had to be told which section means what.
//
// A group is a heading, not a container - nothing collapses, and every section is still exactly
// one click from the top of its page. Nesting the accordions two deep was the other option and is
// worse on every surface: two clicks to reach any field, collapse state that's easy to lose track
// of, and a shape the drill-down apps can't mirror anyway.
public static class SettingsGroups
{
    public const string Libraries = "Libraries & Downloads";
    public const string Notifications = "Notifications";
    public const string Access = "Access & Network";
    public const string Maintenance = "Maintenance";

    // The order the headings appear in: what a new install touches first, to what it touches
    // last, if ever. Clients render groups in this order and put anything they don't recognise
    // at the end.
    public static IReadOnlyList<string> Order { get; } =
        [Libraries, Notifications, Access, Maintenance];

    private static readonly Dictionary<string, int> Positions =
        Order.Select((group, index) => (group, index))
             .ToDictionary(entry => entry.group, entry => entry.index, StringComparer.Ordinal);

    // An unknown group sorts last rather than throwing.
    public static int PositionOf(string group) =>
        Positions.TryGetValue(group, out var position) ? position : Order.Count;
}

public sealed record SettingsSectionSchema
{
    public required string Key { get; init; }
    public required string Title { get; init; }

    // Which heading this section sits under - one of SettingsGroups. Required rather than
    // optional: a section with no group would silently fall to the bottom of every client's page,
    // which is exactly the drift this schema exists to prevent.
    public required string Group { get; init; }

    // The group's position in SettingsGroups.Order, serialized so a client can sort the headings
    // into the intended order without a second request or its own hand-copied list of groups.
    public int GroupOrder => SettingsGroups.PositionOf(Group);

    // Where a PUT of this section's values goes.
    public required string Endpoint { get; init; }

    // Which service has to restart for this section's RequiresRestart fields to take effect.
    // "bridge" for everything that configures the main app - which is all but one section, hence
    // the default. INTERNET EXPOSED MODE is the exception: it binds this dashboard's own Kestrel
    // port, so restarting the bridge would do nothing at all.
    public string RestartService { get; init; } = "server";

    // Where to GET this section's current values, for the sections that aren't part of the bulk
    // /api/settings snapshot. Null for all but one, which is the point: a client fetches the
    // snapshot once and reads every section out of it by key, and only falls back to a per-section
    // request where a section says it needs one.
    //
    // INTERNET EXPOSED MODE is that section - it configures this dashboard project's own Kestrel
    // binding and so lives in the Web project's appsettings.json rather than the main app's. The
    // web dashboard used to handle this by hard-coding the whole section client-side, which is
    // exactly why it was the one section the phone and Mac apps never had. Saying "fetch my values
    // from here" in the schema instead costs one optional property and hands the section to every
    // client at once.
    public string? DataEndpoint { get; init; }

    // Whether the section shows in the dashboard's basic mode. Advanced sections are the ones a
    // typical install never needs to touch.
    public required bool Basic { get; init; }

    public required string Description { get; init; }
    public required IReadOnlyList<SettingsFieldSchema> Fields { get; init; }

    public SettingsActionSchema? ExtraAction { get; init; }

    // The DTO this section's values bind to. Never serialized - it exists so the drift test can
    // walk the schema and check each section against its DTO without a second hand-maintained
    // map that could itself be forgotten. Not `required` like the rest: System.Text.Json refuses
    // to serialize a type whose required property is [JsonIgnore]d, so enforcement falls to
    // SettingsSchemaTests, which dereference this for every section and would throw on a null.
    [JsonIgnore]
    public Type DtoType { get; init; } = null!;
}

public static class SettingsSchema
{
    private static SettingsFieldSchema Text(
        string name, string label, string tip, SettingsLookupSchema? lookup = null,
        SettingsOptionsSourceSchema? optionsSource = null) =>
        new()
        {
            Name = name, Label = label, Type = "text", Tip = tip,
            Lookup = lookup, OptionsSource = optionsSource
        };

    // Mullvad's locations with a WireGuard server right now, from Mullvad's public server list.
    private static readonly SettingsOptionsSourceSchema MullvadLocations = new(
        "Mullvad locations",
        "Lists every country and city where Mullvad has a WireGuard server right now, so you can pick one instead of looking up its code.",
        "/api/settings/media-downloads/mullvad-locations",
        "Mullvad's server list came back empty. Type a country code like se instead.",
        "Type a country code (se, nl, ch, us) or a city code (se-sto, nl-ams).");

    private static SettingsFieldSchema Password(string name, string label, string tip) =>
        new() { Name = name, Label = label, Type = "password", Tip = tip };

    private static SettingsFieldSchema Check(string name, string label, string tip) =>
        new() { Name = name, Label = label, Type = "checkbox", Tip = tip };

    private static SettingsFieldSchema Csv(string name, string label, string tip) =>
        new() { Name = name, Label = label, Type = "csv", Tip = tip };

    private static SettingsFieldSchema Number(
        string name, string label, string tip, double min, double max, double? step = null,
        double? recommended = null) =>
        new()
        {
            Name = name, Label = label, Type = "number", Tip = tip,
            Min = min, Max = max, Step = step, Recommended = recommended
        };

    private static SettingsFieldSchema Select(
        string name, string label, string tip, params (string Value, string Label)[] options) =>
        new()
        {
            Name = name,
            Label = label,
            Type = "select",
            Tip = tip,
            Options = options.Select(o => new SettingsFieldOption(o.Value, o.Label)).ToArray()
        };

    // The sections as written below. Sections - the one clients see - is this run through
    // WithDerivedFlags, which fills in the per-field flags that are read off the DTOs rather than
    // typed out by hand. Declared first, because static initializers run in textual order.
    private static readonly IReadOnlyList<SettingsSectionSchema> Declared =
    [
        new()
        {
            Key = "media",
            Title = "MOVIES & TV",
            Group = SettingsGroups.Libraries,
            Endpoint = "/api/settings/media",
            Basic = true,
            DtoType = typeof(MediaSettingsDto),
            Description = "A family movie and TV library, like Jellyfin, on the web and in every app including Apple TV. Point it at folders of movies and TV shows (on this server, or on another computer's share mounted here) from the Movies tab; it reads the titles from the file names, fetches official posters, descriptions and ratings from TMDB, and streams to each device in a format it can play. Everyone who signs in gets their own watched list and resume points.",
            Fields =
            [
                Check("enabled", "Enabled", "Show the Movies tab on the web and in the apps. Turning it off hides it everywhere but keeps the libraries and everyone's watched history."),
                Password("tmdbApiKey", "TMDB API Key", "Free from themoviedb.org: make an account, then Settings -> API -> request a key (Personal use). Either the \"API Key\" or the longer \"API Read Access Token\" works. Without one the library still plays, but uses the file names as titles and shows only artwork that sits beside the files."),
                Number("rescanHours", "Rescan Every (hours)", "How often the library folders are checked for new files. The server also checks at startup and whenever a library is added. 0 turns the periodic check off; the Scan button on the Movies tab still works.", 0, 168)
            ],
            ExtraAction = new SettingsActionSchema("rescanMedia", "scan now", "Checks every library folder for new, moved or deleted files right away, then fetches anything missing from TMDB.", "/api/media/scan", "POST")
        },
        // MARK: Music (MusicEndpoints, docs/MUSIC_AND_PODCASTS.md)
        new()
        {
            Key = "music",
            Title = "MUSIC",
            Group = SettingsGroups.Libraries,
            Endpoint = "/api/settings/music",
            Basic = true,
            DtoType = typeof(MusicSettingsDto),
            Description = "The household's own music, on the web and in every app including Apple TV. Point it at folders of music files (on this server, or shared from another computer) under Music -> Libraries; it reads each file's tags and cover art, fills in missing album covers and lyrics if allowed, and streams every track in a format the device can play. Everyone who signs in gets their own plays, loves, ratings, playlists and mixes.",
            Fields =
            [
                Check("enabled", "Enabled", "Show the Music tab on the web and in the apps. Turning it off hides it everywhere but keeps the libraries, playlists and everyone's listening history."),
                Number("rescanHours", "Rescan Every (hours)", "How often the music folders are checked for new, changed or deleted files. The server also checks at startup and whenever a library is added. 0 turns the periodic check off; Scan under Music -> Libraries still works.", 0, 168),
                Check("fetchArtworkOnline", "Find Missing Album Covers", "For albums with no cover in their files or folder, look the album up on MusicBrainz and fetch its cover from the Cover Art Archive. Only the artist and album names leave this server."),
                Check("fetchLyricsOnline", "Find Missing Lyrics", "For tracks with no lyrics of their own, look them up on LRCLIB the first time someone opens the lyrics. Only the artist, title, album and length leave this server."),
                Number("transcodeBitrate", "Converted Quality (kbps)", "The AAC bitrate used when a file has to be converted for a device that cannot play it as it is (a FLAC on an older TV, say), and for data saver when a device does not say. 256 is indistinguishable from the original for nearly everyone; lower saves mobile data.", 96, 320)
            ],
            ExtraAction = new SettingsActionSchema("rescanMusic", "scan now", "Checks every music folder for new, changed or deleted files right away, then fills in covers and tags for anything new.", "/api/music/scan", "POST")
        },
        new()
        {
            Key = "mediaDownloads",
            Title = "MOVIE DOWNLOADS",
            Group = SettingsGroups.Libraries,
            Endpoint = "/api/settings/media-downloads",
            Basic = true,
            DtoType = typeof(MediaDownloadsSettingsDto),
            Description = "Off by default. Adds \"+ Add\" to the Movies tab: search for a movie or TV episodes, pick one of the torrents your sites offer, and it downloads and appears in the library by itself. The searching and downloading are done by Prowlarr and qBittorrent, which only ever reach the internet through your VPN - if the VPN drops they are cut off rather than falling back to your home connection. On Linux, run server/downloads/install-downloads.sh on this server once with your VPN provider's WireGuard (.conf) or OpenVPN (.ovpn) file; this server then starts the VPN and both programs when someone searches or downloads, and stops them again when nothing has needed them for a few minutes. Torrent sites are added on the Movies tab under Downloads -> Sites. What you download is your responsibility: only download what you have the right to.",
            Fields =
            [
                Check("enabled", "Enabled", "Show \"+ Add\" and Downloads on the Movies tab. Needs MOVIES & TV turned on and a movie (or TV) library on one of this server's own disks to save into."),
                Select("vpnProvider", "VPN Provider", "Where the VPN's settings come from. Mullvad needs only your account number: this server makes its own WireGuard key, registers it on your account as one device, and picks a server in the location below. Another WireGuard provider (ProtonVPN, IVPN, Surfshark, Windscribe, AirVPN...) takes five values from the WireGuard file its website gives you. The installed file is whatever install-downloads.sh was given - the only way to use an OpenVPN (.ovpn) provider such as NordVPN or PIA.",
                    (MediaVpnProviders.Installed, "The file installed on the server"), (MediaVpnProviders.Mullvad, "Mullvad (account number)"), (MediaVpnProviders.WireGuard, "Another WireGuard provider")),
                Password("mullvadAccountNumber", "Mullvad Account Number", "Mullvad only. The 16-digit number you sign in to mullvad.net with. Uses one of the account's five device slots; it shows on mullvad.net under Devices and can be removed there."),
                Text("mullvadLocation", "Mullvad Location", "Mullvad only. A country code (se = any city in Sweden) or a city (se-sto = Stockholm). Nearby countries are faster; Sweden, the Netherlands and Switzerland are popular for downloads.", optionsSource: MullvadLocations),
                Password("wireGuardPrivateKey", "WireGuard Private Key", "Another WireGuard provider only. The PrivateKey line of the WireGuard (.conf) file from your provider's website, under [Interface]."),
                Text("wireGuardAddress", "WireGuard Address", "Another WireGuard provider only. The Address line under [Interface], e.g. 10.2.0.2/32 - several separated by commas."),
                Text("wireGuardDns", "WireGuard DNS", "Another WireGuard provider only. The DNS line under [Interface], e.g. 10.2.0.1. Blank uses public DNS, still through the tunnel."),
                Text("wireGuardServerPublicKey", "Server Public Key", "Another WireGuard provider only. The PublicKey line under [Peer]."),
                Text("wireGuardServerEndpoint", "Server Endpoint", "Another WireGuard provider only. The Endpoint line under [Peer], e.g. 185.159.157.1:51820."),
                Check("useVpn", "Use VPN For Movie Downloads", "On (recommended): searching and downloading only ever go through your VPN, and nothing starts until the server has proven the sites see the VPN's address and not your home's. Off: they use your home internet connection directly, so the sites, the other people sharing and your internet provider all see your home address - the Movies tab shows an amber warning while it is off."),
                Select("allowedUsers", "Who Can Add", "Who may search and start downloads. Managing the list of sites is always admins only.",
                    ("admins", "Admins only"), ("everyone", "Everyone who can sign in")),
                Select("preferredQuality", "Preferred Quality", "Which releases are listed first. 1080p is the best fit for most TVs and phones; 4K files are three to five times the size.",
                    ("1080p", "1080p (HD)"), ("2160p", "2160p (4K)"), ("720p", "720p (smaller)"), (MediaDownloadsSettingsDto.QualityAny, "No preference")),
                Number("seedMinutes", "Share Back For (minutes)", "How long a finished download keeps sharing before it is filed into the library and the torrent removed. 0 files it straight away. Private sites that require sharing back need this raised.", 0, 10080),
                Number("stallMinutes", "Give Up On A Stuck Download After (minutes)", "A download that gets nothing for this long - usually because nobody is sharing that copy any more - is stopped and the next-best copy people are sharing is tried instead, up to three copies. 0 waits for ever.", 0, 1440),
                Number("idleMinutes", "Switch Off After (minutes)", "The VPN, qBittorrent and Prowlarr are stopped once nothing has been searched or downloaded for this long, and started again the next time someone does.", 1, 240),
                Check("manageServices", "Start And Stop The Services", "On: this server starts and stops the VPN, qBittorrent and Prowlarr that install-downloads.sh installed. Off: they are already running somewhere you look after, at the addresses below."),
                Text("prowlarrUrl", "Prowlarr Address", "Where Prowlarr answers. install-downloads.sh puts it at http://10.251.0.2:9696, inside the VPN."),
                Password("prowlarrApiKey", "Prowlarr API Key", "Leave blank when install-downloads.sh set Prowlarr up - the key is read from Prowlarr's own configuration. Otherwise paste it from Prowlarr -> Settings -> General."),
                Text("qbittorrentUrl", "qBittorrent Address", "Where qBittorrent's Web UI answers. install-downloads.sh puts it at http://10.251.0.2:8080, inside the VPN. It must run on this same machine: finished files are moved, not copied over the network."),
                Text("qbittorrentUsername", "qBittorrent Username", "Leave blank when install-downloads.sh set qBittorrent up (it lets this server in without one)."),
                Password("qbittorrentPassword", "qBittorrent Password", "Only needed with a username.")
            ]
        },
        // ---- Podcasts (MUSIC_AND_PODCASTS.md §1) ----
        new()
        {
            Key = "podcasts",
            Title = "PODCASTS",
            Group = SettingsGroups.Libraries,
            Endpoint = "/api/settings/podcasts",
            Basic = true,
            DtoType = typeof(PodcastSettingsDto),
            Description = "A podcast app for the whole household, on the web and in every app. Follow shows from Apple's directory or by their feed address; this server checks the feeds, downloads new episodes onto its own disk and keeps them even after a show drops them from its feed, so the apps play them from here. Per show it can also even out the volume and cut long silences, and it can write transcripts with whisper.cpp so every episode is searchable. Everyone who signs in gets their own subscriptions, Up Next, progress and bookmarks.",
            Fields =
            [
                Check("enabled", "Enabled", "Show the Podcasts tab on the web and in the apps. Turning it off hides it everywhere and stops checking feeds, but keeps every show, download and everyone's progress."),
                Text("downloadFolder", "Download Folder", "Where downloaded episodes are kept, on one of this server's own disks. Blank keeps them in the data folder beside the database. Changing it does not move episodes already downloaded; they are fetched again into the new folder when wanted."),
                Number("refreshMinutes", "Check Feeds Every (minutes)", "How often each followed show's feed is checked for new episodes. Shows nobody follows any more are not checked at all.", 15, 1440),
                Check("autoDownloadNew", "Download New Episodes", "The starting choice for each newly followed show: download new episodes onto the server as they come out, so they play instantly and keep working if the publisher's server is slow. Each show can be changed afterwards."),
                Number("keepEpisodes", "Keep Episodes Per Show", "The starting choice for newly followed shows: how many of the newest downloaded episodes to keep per show. Older downloads are removed (they still play straight from the publisher). 0 keeps them all. Episodes in someone's Up Next are never removed for this.", 0, 1000),
                Number("deletePlayedAfterDays", "Delete Played After (days)", "A downloaded episode everyone has finished is removed this many days later, and so are downloads of shows nobody follows any more. The episode stays in the list. 0 never removes them.", 0, 365),
                Number("maxStorageGb", "Storage Limit (GB)", "The most space downloaded episodes may take. Past it, played episodes are removed first, then the oldest. 0 means no limit.", 0, 100000),
                Text("directoryCountry", "Directory Country", "The two-letter country code of the Apple Podcasts store to search and take Top Shows from, e.g. us, gb, ca, au or de."),
                Check("transcriptsEnabled", "Write Transcripts", "Off by default. Writes a transcript of episodes on this server with whisper.cpp, for shows set to transcribe and whenever someone asks for one, so they can be read along and searched. Shows that publish their own transcripts never need this. It is slow on a small machine: expect an hour-long episode to take 10-30 minutes with a base model on a CPU."),
                Text("whisperCommand", "Whisper Command", "The whisper.cpp program. whisper-cli finds it on the PATH; otherwise give its full path, e.g. /usr/local/bin/whisper-cli. On a Mac: brew install whisper-cpp. On Linux: build it from github.com/ggerganov/whisper.cpp."),
                Text("whisperModel", "Whisper Model", "The full path to a ggml model file from huggingface.co/ggerganov/whisper.cpp. ggml-base.en.bin (150 MB) is a good start for English; ggml-small.bin is more accurate, slower, and handles other languages."),
                Number("whisperThreads", "Whisper Threads", "How many CPU threads whisper may use. More is faster but slows everything else on the server while a transcript is being written.", 1, 32)
            ],
            ExtraAction = new SettingsActionSchema("refreshPodcasts", "refresh now", "Checks every followed show's feed for new episodes right away, instead of waiting for the next scheduled check.", "/api/podcasts/refresh", "POST")
        },
        // ---- end Podcasts ----
        new()
        {
            Key = "email",
            Title = "EMAIL",
            Group = SettingsGroups.Notifications,
            Endpoint = "/api/settings/email",
            Basic = true,
            DtoType = typeof(EmailSettingsDto),
            Description = "The mail account ReelHouse writes to you from: a failed sign-in (LOGIN ALERTS), or the download VPN's account running low. Works with any SMTP provider - Gmail, Outlook, iCloud, Fastmail, your own mail server, or a sending service like SES or SendGrid. Most consumer providers need an app password here rather than your normal one.",
            Fields =
            [
                Check("enabled", "Enabled", "Send email when there is something to tell you."),
                Text("smtpHost", "SMTP Host", "Outgoing mail server your provider gives you, e.g. smtp.gmail.com, smtp.office365.com, smtp.fastmail.com."),
                Number("smtpPort", "SMTP Port", "Port for the mail server. 587 is the usual one; 465 also works for providers that ask for it. Use whichever number your provider's own instructions give.", 1, 65535),
                Check("enableSsl", "Enable SSL", "Encrypt the connection to the mail server. Leave on. Turn it off only for a mail relay on your own network that has no certificate - and never on port 465, which is encrypted from the start."),
                Text("username", "Username", "Account used to log in to the mail server - usually your full email address, but some services use a key or a name instead. Leave blank for a relay on your own network that needs no login."),
                Password("appPassword", "Password", "The password for that account. Gmail, Outlook, iCloud and Yahoo all refuse your normal one here and want an app password generated in their security settings instead."),
                Text("fromAddress", "From Address", "Address the message appears to come from. Required if the username above isn't itself an email address; otherwise it falls back to the username."),
                Text("fromName", "From Name", "Display name shown as the sender, e.g. ReelHouse."),
                Text("toAddress", "To Address", "Where messages are sent."),
                Number("timeoutSeconds", "Timeout (sec)", "How long to wait for the mail server before giving up on one message.", 5, 300)
            ],
            ExtraAction = new SettingsActionSchema(
                "sendTestEmail",
                "send test email",
                "Send a plain test message to the To Address using the settings above, and say what the mail server answered. Save first - this tests what is saved, not what is currently typed in the boxes. It sends even while Enabled is off.",
                "/api/notifications/test/email",
                "POST")
        },
        new()
        {
            Key = "pushNotifications",
            Title = "PUSH NOTIFICATIONS",
            Group = SettingsGroups.Notifications,
            Endpoint = "/api/settings/push",
            Basic = true,
            DtoType = typeof(PushNotificationSettingsDto),
            Description = "Notifications on the iPhone and Android apps' lock screens: a new episode of a podcast you follow, a movie or show you asked for finishing its download, a failed sign-in, or a problem with the server. With a ReelHouse license installed (LICENSE) they go out through the ReelHouse push service and there is nothing else to set up. The Apple and Firebase fields are only for running with your own developer keys instead (an app you built yourself) - filled in, they take over from the push service for that kind of phone. Each phone also has to allow notifications in its own ReelHouse app. The Apple TV can't show notifications, so it never gets any. See docs/PUSH.md.",
            Fields =
            [
                Check("enabled", "Enabled", "Send push notifications to the ReelHouse apps. The switches below pick which kinds; the test button works even while this is off."),
                Check("newEpisodes", "New Podcast Episodes", "Tell people when a show they follow has a new episode. Each person can still turn it off per show with \"Notify me of new episodes\" on the show's page."),
                Check("downloads", "Finished Downloads", "Tell whoever asked for a movie, episode or album (+ Add) when it's downloaded and in the library."),
                Check("loginAlerts", "Failed Sign-ins", "Tell the admins when someone gets a password wrong. Uses the cooldown from LOGIN ALERTS, so a burst of guesses is one notification. Doesn't need LOGIN ALERTS' email turned on."),
                Check("serverAlerts", "Server Problems", "Tell the admins about problems with the server itself, like the download VPN's account running out."),
                Check("wakeAlarms", "Missed Wake-up Alarms", "Tell someone when their wake-up alarm couldn't play on its speaker."),
                Check("relayEnabled", "Use ReelHouse Push Service", "Send through the ReelHouse push service, which holds the Apple and Google keys for the ReelHouse apps, so you need no developer account. Needs a ReelHouse license (LICENSE) - the license is what identifies this server to it. Only a notification's title, text and what it opens pass through it. Ignored for iPhones if the Apple fields below are filled in, and for Android if the Firebase ones are."),
                Text("relayUrl", "Push Service Address", "Leave at https://push.nr5p.com unless you've been given a different one."),
                Text("appleTeamId", "Apple: Team ID", "Your Apple Developer Team ID - the 10-character code under Membership Details at developer.apple.com."),
                Text("appleKeyId", "Apple: Key ID", "The ID of your APNs key (Certificates, Identifiers & Profiles -> Keys). One key works for every app on your team."),
                Text("applePrivateKeyPath", "Apple: Key File", "Where the key's .p8 file is on this server. A full path, or just the file name if you put it in ReelHouse's data folder. The file is the secret - keep it readable by this service only."),
                Text("appleBundleId", "Apple: Bundle ID", "The iPhone app's bundle identifier. Leave as com.reelhouse.client unless you built the app under a different one."),
                Text("firebaseProjectId", "Firebase: Project ID", "The Project ID from your Firebase project's settings page. The Android app must be built with that project's google-services.json."),
                Text("firebaseServiceAccountPath", "Firebase: Service Account File", "Where the project's service-account .json file is on this server (Project settings -> Service accounts -> Generate new private key). A full path, or just the file name if it's in the data folder. The file is the secret.")
            ],
            ExtraAction = new SettingsActionSchema(
                "sendTestPush",
                "send test notification",
                "Sends a test notification to your own phones - the ones signed in to ReelHouse as you with notifications allowed - and says how many it reached. Save first: it tests what is saved. Works even while Enabled is off.",
                "/api/push/test",
                "POST")
        },
        new()
        {
            Key = "logging",
            Title = "LOGGING",
            Group = SettingsGroups.Maintenance,
            Endpoint = "/api/settings/logging",
            Basic = false,
            DtoType = typeof(LoggingSettingsDto),
            Description = "How much detail the server writes to its own log. Information is the right day-to-day level; drop to Debug only while chasing a specific problem, since it's noisy and makes the log large. Changes apply immediately, no restart needed.",
            Fields =
            [
                Select("default", "Default Level", "Log detail for the app's own components. Debug shows everything, step by step; Warning and above keeps the log nearly silent unless something is wrong.",
                    ("Trace", "Trace (most detail)"),
                    ("Debug", "Debug"),
                    ("Information", "Information (default)"),
                    ("Warning", "Warning"),
                    ("Error", "Error"),
                    ("Critical", "Critical"),
                    ("None", "None (silent)")),
                Select("microsoftAspNetCore", "ASP.NET Core Level", "Log detail for the web framework itself - request handling, routing, connections. Kept at Warning by default because Information logs every single HTTP request.",
                    ("Trace", "Trace (most detail)"),
                    ("Debug", "Debug"),
                    ("Information", "Information"),
                    ("Warning", "Warning (default)"),
                    ("Error", "Error"),
                    ("Critical", "Critical"),
                    ("None", "None (silent)"))
            ]
        },
        new()
        {
            Key = "server",
            Title = "SERVER ADDRESS",
            Group = SettingsGroups.Access,
            Endpoint = "/api/settings/server",
            Basic = false,
            DtoType = typeof(ServerSettingsDto),
            Description = "The plain-HTTP address and port ReelHouse listens on. Get this wrong and the server comes back unreachable after its next restart - fixable only by editing data/settings.json on the server itself, so double-check before saving. Takes effect on restart. The web page also shows this machine's own IP address here - that's the address to type into the apps, and it isn't a setting.",
            Fields =
            [
                new()
                {
                    Name = "urls",
                    Label = "Listen Address(es)",
                    Type = "text",
                    Tip = "Where ReelHouse listens for connections, e.g. http://0.0.0.0:3350. 0.0.0.0 means every network interface on the machine; 127.0.0.1 means this machine only. Multiple addresses can be separated with semicolons.",
                    RequiresRestart = true
                }
            ]
        },
        new()
        {
            Key = "internetExposed",
            Title = "INTERNET EXPOSED MODE",
            Group = SettingsGroups.Access,
            Endpoint = "/api/settings/internet-exposed",
            // Not in the bulk snapshot, and not the bridge's port to rebind - see the two
            // properties' own notes above. Both exceptions are declared rather than special-cased
            // in any client.
            DataEndpoint = "/api/settings/internet-exposed",
            
            Basic = false,
            DtoType = typeof(InternetExposedSettingsDto),
            Description = "For reaching ReelHouse from outside your home network - e.g. through a Cloudflare Tunnel. When enabled, this server listens on a SECOND port that always requires login and only accepts HTTPS connections, no matter how Login and HTTPS are configured. The normal port for local network use is completely unaffected by this - point your tunnel or reverse proxy at the new port instead, not the regular one. Requires local HTTPS to already be configured and at least one account to already exist. Takes effect after a restart.",
            Fields =
            [
                new()
                {
                    Name = "enabled",
                    Label = "Enabled",
                    Type = "checkbox",
                    Tip = "Turn on the dedicated internet-exposed port. Requires HTTPS to already be configured and at least one account to exist. Needs a restart to take effect - use the restart button below.",
                    RequiresRestart = true
                },
                new()
                {
                    Name = "port",
                    Label = "Port",
                    Type = "number",
                    Tip = "Port for internet-facing traffic. Point your Cloudflare Tunnel (or other reverse proxy) here instead of the normal port. Must be different from the HTTPS port. Needs a restart to take effect - use the restart button below.",
                    Min = 1,
                    Max = 65535,
                    RequiresRestart = true
                }
            ]
        },
        new()
        {
            Key = "loginAlerts",
            Title = "LOGIN ALERTS",
            Group = SettingsGroups.Access,
            Endpoint = "/api/settings/login-alerts",
            Basic = true,
            DtoType = typeof(LoginAlertSettingsDto),
            Description = "Emails you when someone enters the wrong password for ReelHouse, using the EMAIL account above. Off by default. One alert is sent per source IP per cooldown window, no matter how many usernames or passwords are tried against it, so a brute-force burst doesn't flood you.",
            Fields =
            [
                Check("enabled", "Enabled", "Email you when someone fails to sign in to ReelHouse."),
                Number("cooldownMinutes", "Cooldown (min)", "After alerting on a failed login from a given address, suppress further alerts from that same address for this many minutes - so one attacker hammering the login page sends one alert, not one per attempt.", 1, 1440)
            ]
        }
    ];

    public static IReadOnlyList<SettingsSectionSchema> Sections { get; } = WithDerivedFlags(Declared);

    // Fills in the field flags that are read off the DTO instead of being written out per field.
    // Currently that is Integer alone; anything else derivable belongs here rather than in 67
    // hand-typed call sites that would each be one edit away from disagreeing with the DTO.
    private static IReadOnlyList<SettingsSectionSchema> WithDerivedFlags(
        IReadOnlyList<SettingsSectionSchema> sections) =>
        sections
            .Select(section => section with
            {
                Fields = section.Fields
                    .Select(field => field.Type == "number"
                        ? field with { Integer = IsIntegral(section.DtoType, field.Name) }
                        : field)
                    .ToArray()
            })
            .ToArray();

    // Walks a dotted camelCase field name ("apple.teamId", "minimumConfidence") down to the
    // property it binds to. A name that resolves to nothing returns false rather than throwing:
    // SettingsSchemaTests is what fails the build on a field with no matching property, and it
    // gives a far better message than a NullReferenceException during static initialization.
    private static bool IsIntegral(Type dtoType, string fieldName)
    {
        var current = dtoType;
        var segments = fieldName.Split('.');

        for (var i = 0; i < segments.Length; i++)
        {
            var property = current?.GetProperties(BindingFlags.Public | BindingFlags.Instance)
                .FirstOrDefault(p => string.Equals(
                    JsonNamingPolicy.CamelCase.ConvertName(p.Name), segments[i], StringComparison.Ordinal));

            if (property is null) return false;

            var underlying = Nullable.GetUnderlyingType(property.PropertyType) ?? property.PropertyType;
            if (i == segments.Length - 1)
                return underlying == typeof(int) || underlying == typeof(long);

            current = underlying;
        }

        return false;
    }
}
