// The page shell: the connection light, tooltips, the build line in the footer and switching
// between the tabs. Each tab's own file (movies.js, music.js, podcasts.js, settings.js,
// accounts.js) does everything inside its tab.

const HEALTH_INTERVAL_MS = 30_000;

const statusDotEl = document.getElementById("status-dot");
const statusTextEl = document.getElementById("status-text");
const buildVersionEl = document.getElementById("build-version");

function setStatus(online) {
  statusDotEl.classList.toggle("online", online);
  statusDotEl.classList.toggle("offline", !online);
  statusTextEl.textContent = online ? "connected" : "can't reach the server";
}

function escapeHtml(value) {
  // A string replace rather than the textContent/innerHTML trick: that one leaves quotes alone,
  // and half the interpolations in this page are into attributes, where a surviving double quote
  // ends the attribute and everything after it is parsed as more attributes.
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Tooltips render to the right of their element by default, which runs off-screen for anything
// near the right edge. Rather than hand-tagging each one - and missing the dynamically rendered
// ones - measure and flip them to right-aligned as needed.
const TIP_WIDTH = 300; // max-width plus padding and border

function anchorTooltips() {
  const viewportWidth = document.documentElement.clientWidth;
  for (const el of document.querySelectorAll("[data-tip]")) {
    const box = el.getBoundingClientRect();
    if (!box.width) continue;
    const runsOffRight = box.left + TIP_WIDTH > viewportWidth;
    const flippingFits = box.right - TIP_WIDTH >= 0;
    el.toggleAttribute("data-tip-right", runsOffRight && flippingFits);
  }
}

let tipAnchorTimer;
function scheduleTooltipAnchoring() {
  clearTimeout(tipAnchorTimer);
  tipAnchorTimer = setTimeout(anchorTooltips, 60);
}
window.ReelHouseTooltips = { schedule: scheduleTooltipAnchoring };

// childList covers elements being added. It does NOT cover a class toggle like switching the
// active tab or opening a settings section - those don't add or remove nodes, so the spots that
// do them call scheduleTooltipAnchoring() directly (the tab-click handler below, settings.js).
new MutationObserver(scheduleTooltipAnchoring).observe(document.body, { childList: true, subtree: true });
window.addEventListener("resize", scheduleTooltipAnchoring);
anchorTooltips();

// /api/health is unauthenticated, so it answers whether or not anyone is signed in - which makes
// it the connection light as well as the source of the build line in the footer.
async function checkHealth() {
  try {
    const response = await fetch("/api/health", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const { build } = await response.json();
    setStatus(true);
    if (build?.display && !buildVersionEl.dataset.loaded) {
      buildVersionEl.dataset.loaded = "true";
      buildVersionEl.textContent = `ReelHouse build ${build.display}`;
      buildVersionEl.classList.toggle("dirty", build.isDirty === true);
    }
  } catch {
    setStatus(false);
  }
}

checkHealth();
setInterval(checkHealth, HEALTH_INTERVAL_MS);

// ---------------- Tabs ----------------

// Scoped to the top nav on purpose: Movies, Music and Podcasts have their own .tab buttons for
// their sub-panes, and a bare ".tab" selector would pick those up too.
const tabs = document.querySelectorAll("#tabs .tab");
const views = {
  empty: document.getElementById("view-empty"),
  movies: document.getElementById("view-movies"),
  music: document.getElementById("view-music"),
  podcasts: document.getElementById("view-podcasts"),
  settings: document.getElementById("view-settings"),
  accounts: document.getElementById("view-accounts")
};
let settingsLoaded = false;
let currentView = "empty";

function showView(target) {
  for (const t of tabs) t.classList.toggle("active", t.dataset.view === target);
  for (const [name, el] of Object.entries(views)) el.classList.toggle("hidden", name !== target);
}

for (const tab of tabs) {
  tab.addEventListener("click", async () => {
    const target = tab.dataset.view;
    showView(target);

    // Closes the player and stops the scan-status poll - a film must not keep streaming (and
    // reporting progress) behind another tab.
    if (currentView === "movies" && target !== "movies") window.ReelHouseMovies.hide();
    // Leaving Music or Podcasts only stops their polling - the player bar keeps playing on
    // every tab, which is the point of it.
    if (currentView === "music" && target !== "music") window.ReelHouseMusic.hide();
    if (currentView === "podcasts" && target !== "podcasts") window.ReelHousePodcasts.hide();

    if (target === "settings" && !settingsLoaded) {
      settingsLoaded = true;
      window.ReelHouseSettings.load();
    }
    // Each reads the rest of the hash itself (#movies/item/<id>, #music/album/<id>,
    // #podcasts/show/<id>, ...), so a refresh or the back button lands on the same page.
    if (target === "movies") window.ReelHouseMovies.show();
    if (target === "music") window.ReelHouseMusic.show();
    if (target === "podcasts") window.ReelHousePodcasts.show();
    if (target === "accounts") {
      await window.ReelHouseAccounts.load();
      window.ReelHouseAccounts.renderList();
    }

    currentView = target;
    scheduleTooltipAnchoring();
  });
}

function visibleTabs() {
  return Array.from(tabs).filter((tab) => !tab.classList.contains("hidden"));
}

// A link can land on a tab: /#settings opens Settings, and /#movies/item/<id> and the other
// sub-routes land on their tab, whose own show() reads the part after the slash.
function landOnHash() {
  let wanted = location.hash.replace(/^#/, "").split("/")[0];
  const landing = wanted && visibleTabs().find((tab) => tab.dataset.view === wanted);
  // Clicked even when that tab is already open: its show() is what reads the rest of the hash,
  // so #movies/libraries from inside Movies has to go through it too.
  if (landing) {
    landing.click();
    return true;
  }
  return false;
}

// With no hash (or one naming a tab that isn't shown), open the first tab there is: Movies,
// else Music, else Podcasts, else Settings. Run once sign-in is settled, because which tabs exist
// depends on who is signed in and on what is switched on in Settings.
function landOnFirstTab() {
  if (landOnHash()) return;
  if (currentView !== "empty" && views[currentView] && !document.getElementById(`tab-${currentView}`)?.classList.contains("hidden")) return;
  const first = visibleTabs()[0];
  if (first) {
    first.click();
    return;
  }
  showView("empty");
  currentView = "empty";
  document.getElementById("empty-view-text").textContent =
    "Movies & TV, Music and Podcasts are all switched off on this server. An admin can turn them on in Settings.";
}

window.addEventListener("hashchange", landOnHash);

window.ReelHouseShell = { landOnFirstTab };

(async () => {
  const signedIn = await window.ReelHouseAuth.check();
  if (!signedIn) return;
  landOnFirstTab();
  window.ReelHouseExposure.check();
  // The welcome is about setting the server up, which only an admin can do.
  if (window.ReelHouseAuth.isAdmin()) window.ReelHouseWizard.checkAndMaybeShow();
})();
