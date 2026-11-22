// The first-run welcome: two short steps an admin sees once, after the admin account exists (the
// sign-in box in auth.js creates that). Nothing here is a setting - the second step only takes
// you to the real library screens, so the folder picker and network shares work the same way
// they always do. Finishing or skipping marks setup done (POST /api/setup/complete); Settings is
// where everything is changed afterwards.
window.ReelHouseWizard = (function () {
  const overlay = document.getElementById("setup-wizard");
  const titleEl = document.getElementById("wizard-title");
  const stepCountEl = document.getElementById("wizard-step-count");
  const bodyEl = document.getElementById("wizard-body");
  const errorsEl = document.getElementById("wizard-errors");
  const backBtn = document.getElementById("wizard-back-btn");
  const skipBtn = document.getElementById("wizard-skip-btn");
  const nextBtn = document.getElementById("wizard-next-btn");

  let stepIndex = 0;

  const STEPS = [
    {
      title: "WELCOME TO REELHOUSE",
      render() {
        bodyEl.innerHTML = `
          <p>ReelHouse keeps your own movies, TV shows, music and podcasts on this server and plays
          them here, in the ReelHouse apps and on any speaker that has <b>Let others play here</b>
          turned on.</p>
          <p>Everything is in four places: <b>Movies</b>, <b>Music</b> and <b>Podcasts</b>, plus
          <b>Settings</b> for libraries, downloads, email and sign-in. Nothing in this welcome is
          final, and you can skip it.</p>`;
      }
    },
    {
      title: "ADD A FIRST LIBRARY",
      render() {
        const moviesOn = !document.getElementById("tab-movies").classList.contains("hidden");
        const musicOn = !document.getElementById("tab-music").classList.contains("hidden");
        bodyEl.innerHTML = `
          <p>A library is a folder of videos or music - on this server, or shared from another
          computer on your network. ReelHouse scans it, fetches artwork and keeps watching it for
          new files.</p>
          <div class="wizard-library-choices">
            <button type="button" class="btn" id="wizard-add-movies" ${moviesOn ? "" : "disabled"}>add a movies or TV library</button>
            <button type="button" class="btn" id="wizard-add-music" ${musicOn ? "" : "disabled"}>add a music library</button>
          </div>
          <p class="wizard-hint">${moviesOn || musicOn
            ? "Either button finishes this welcome and opens the library screen, with a folder picker for this server and for network shares."
            : "Movies & TV and Music are both switched off. Turn them on in Settings, then add libraries there."}
          Podcasts need no library - follow shows from Podcasts → discover.</p>`;
        document.getElementById("wizard-add-movies").addEventListener("click", () => finish("#movies/libraries"));
        document.getElementById("wizard-add-music").addEventListener("click", () => finish("#music"));
      }
    }
  ];

  function showErrors(messages) {
    errorsEl.innerHTML = "";
    for (const message of messages) {
      const li = document.createElement("li");
      li.textContent = message;
      errorsEl.appendChild(li);
    }
  }

  function renderStep() {
    const step = STEPS[stepIndex];
    titleEl.textContent = step.title;
    stepCountEl.textContent = `step ${stepIndex + 1} of ${STEPS.length}`;
    showErrors([]);
    backBtn.classList.toggle("hidden", stepIndex === 0);
    skipBtn.textContent = stepIndex === STEPS.length - 1 ? "not now" : "skip";
    nextBtn.textContent = stepIndex === STEPS.length - 1 ? "done" : "next";
    step.render();
  }

  // Marks setup done, closes, and optionally goes somewhere. A failure to save only means the
  // welcome shows again next time, so the page carries on either way.
  async function finish(hash) {
    nextBtn.disabled = skipBtn.disabled = true;
    try {
      const response = await fetch("/api/setup/complete", { method: "POST" });
      if (!response.ok) showErrors([`Couldn't save that setup is done (HTTP ${response.status}) - this welcome will show again next time.`]);
    } catch {
      showErrors(["Couldn't reach the server - this welcome will show again next time."]);
    } finally {
      nextBtn.disabled = skipBtn.disabled = false;
    }
    overlay.classList.add("hidden");
    if (hash) location.hash = hash;
  }

  nextBtn.addEventListener("click", () => {
    if (stepIndex < STEPS.length - 1) {
      stepIndex++;
      renderStep();
    } else {
      finish(null);
    }
  });
  skipBtn.addEventListener("click", () => finish(null));
  backBtn.addEventListener("click", () => {
    if (stepIndex === 0) return;
    stepIndex--;
    renderStep();
  });

  async function checkAndMaybeShow() {
    try {
      const response = await fetch("/api/setup/status");
      if (!response.ok) return;
      const payload = await response.json();
      if (payload.completed) return;
    } catch {
      return;
    }

    stepIndex = 0;
    overlay.classList.remove("hidden");
    renderStep();
  }

  return { checkAndMaybeShow };
})();
