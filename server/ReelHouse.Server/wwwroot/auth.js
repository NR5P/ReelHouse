window.ReelHouseAuth = (function () {
  const overlay = document.getElementById("login-gate");
  const usernameInput = document.getElementById("login-username");
  const passwordInput = document.getElementById("login-password");
  const submitBtn = document.getElementById("login-submit-btn");
  const errorsEl = document.getElementById("login-errors");
  const logoutBtn = document.getElementById("logout-btn");
  const accountsTab = document.getElementById("tab-accounts");
  const settingsTab = document.getElementById("tab-settings");
  const moviesTab = document.getElementById("tab-movies");
  const titleEl = document.getElementById("login-title");
  const introEl = document.getElementById("login-intro");
  const confirmRow = document.getElementById("login-confirm-row");
  const confirmInput = document.getElementById("login-confirm");

  // A fresh install has no accounts, and the server refuses everything until the first admin
  // exists - so the same overlay doubles as "create your admin account" (see AuthEndpoints'
  // /api/auth/enable).
  let creatingFirstAdmin = false;
  let status = null;

  function useFirstAdminMode() {
    creatingFirstAdmin = true;
    titleEl.textContent = "CREATE ADMIN ACCOUNT";
    introEl.textContent = "Welcome to ReelHouse. Choose the username and password for this server's admin account - you'll use them to sign in here and in the ReelHouse apps.";
    confirmRow.classList.remove("hidden");
    passwordInput.autocomplete = "new-password";
    submitBtn.textContent = "create account";
  }

  function showErrors(messages) {
    errorsEl.innerHTML = "";
    for (const message of messages) {
      const li = document.createElement("li");
      li.textContent = message;
      errorsEl.appendChild(li);
    }
  }

  async function submit() {
    showErrors([]);
    if (creatingFirstAdmin && passwordInput.value !== confirmInput.value) {
      showErrors(["Passwords do not match."]);
      return;
    }
    submitBtn.disabled = true;
    try {
      const response = await fetch(creatingFirstAdmin ? "/api/auth/enable" : "/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: usernameInput.value.trim(), password: passwordInput.value })
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        if (response.status === 429) showErrors(["Too many attempts - wait a few minutes and try again."]);
        else showErrors(payload.errors || [payload.error || (creatingFirstAdmin ? "Could not create the account." : "Sign-in failed.")]);
        return;
      }
      // Simplest way to resume normal start-up with a fresh, authenticated set of requests.
      window.location.reload();
    } catch {
      showErrors(["Network error while signing in."]);
    } finally {
      submitBtn.disabled = false;
    }
  }

  submitBtn.addEventListener("click", submit);
  passwordInput.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    if (creatingFirstAdmin) confirmInput.focus(); else submit();
  });
  confirmInput.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });
  usernameInput.addEventListener("keydown", (e) => { if (e.key === "Enter") passwordInput.focus(); });

  logoutBtn.addEventListener("click", async () => {
    await fetch("/api/auth/logout", { method: "POST" });
    window.location.reload();
  });

  // The Movies tab exists only while Movies & TV is switched on in Settings, and every signed-in
  // role gets it (watched state is per person).
  async function checkMovies() {
    try {
      const response = await fetch("/api/media/enabled");
      if (!response.ok) return;
      const { enabled } = await response.json();
      moviesTab.classList.toggle("hidden", !enabled);
    } catch {
      // Leave the tab hidden.
    }
  }

  // Music and Podcasts are answered by audio-player.js, which also starts its speaker and
  // "continue listening" services once either is on.
  function checkAudio() {
    return window.ReelHouseAudio ? window.ReelHouseAudio.checkEnabled().catch(() => {}) : Promise.resolve();
  }

  // Resolves true once this page may carry on (signed in, or no sign-in needed), false while the
  // sign-in box is up.
  async function check() {
    try {
      const response = await fetch("/api/auth/status");
      const payload = await response.json();
      status = payload;
      logoutBtn.classList.toggle("hidden", !payload.enabled);
      // Meaningless when login isn't required - there's no real account to show or manage,
      // since every request is treated as a synthetic admin (see AuthGateMiddleware).
      accountsTab.classList.toggle("hidden", !payload.enabled);
      // /api/settings is Admin-only server-side once login is required - hide the tab for a
      // signed-in Viewer rather than let them click through to a raw 403.
      settingsTab.classList.toggle("hidden", payload.enabled && payload.role !== "Admin");
      if (payload.authenticated || !payload.enabled) {
        await Promise.all([checkMovies(), checkAudio()]);
        return true;
      }

      settingsTab.classList.add("hidden");
      if (payload.enabled && !payload.configured) useFirstAdminMode();
      overlay.classList.remove("hidden");
      document.getElementById("empty-view-text").textContent = "sign in to continue.";
      usernameInput.focus();
      return false;
    } catch {
      // If the check itself fails, don't lock someone out of a page that might not even have
      // login enabled - fail open on the client. The real security boundary is server-side
      // (AuthGateMiddleware), not this overlay.
      return true;
    }
  }

  function isAdmin() {
    return !status || !status.enabled || status.role === "Admin";
  }

  // checkMovies is also called by settings.js after MOVIES & TV is saved, so switching the
  // section on shows the tab straight away instead of after a reload.
  return { check, checkMovies, isAdmin, status: () => status };
})();
