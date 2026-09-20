(function () {
  var root = document.getElementById("bench-root");
  if (!root) return;
  var scenario = root.getAttribute("data-default-scenario") || "plaintext";
  var os = root.getAttribute("data-default-os") || "linux";
  var arch = root.getAttribute("data-default-arch") || "aarch64";

  function platformId() { return os + "-" + arch; }

  function sync() {
    var platform = platformId();
    root.querySelectorAll("[data-scenario-tab]").forEach(function (tab) {
      var id = tab.getAttribute("data-scenario-tab");
      var on = id === scenario;
      tab.classList.toggle("seg-btn-active", on);
      tab.setAttribute("aria-pressed", on ? "true" : "false");
    });
    root.querySelectorAll("[data-os-btn]").forEach(function (btn) {
      var on = btn.getAttribute("data-os-btn") === os;
      btn.classList.toggle("plat-opt-active", on);
      btn.setAttribute("aria-pressed", on ? "true" : "false");
    });
    root.querySelectorAll("[data-arch-btn]").forEach(function (btn) {
      var on = btn.getAttribute("data-arch-btn") === arch;
      btn.classList.toggle("plat-opt-active", on);
      btn.setAttribute("aria-pressed", on ? "true" : "false");
    });
    var osCurrent = root.querySelector("[data-os-current]");
    var archCurrent = root.querySelector("[data-arch-current]");
    var osActive = root.querySelector('[data-os-btn="' + os + '"]');
    var archActive = root.querySelector('[data-arch-btn="' + arch + '"]');
    if (osCurrent && osActive) osCurrent.textContent = osActive.textContent.trim();
    if (archCurrent && archActive) archCurrent.textContent = archActive.textContent.trim();
    root.querySelectorAll(".chart-panel, .rank-panel").forEach(function (panel) {
      var match = panel.getAttribute("data-scenario") === scenario &&
                  panel.getAttribute("data-platform") === platform;
      panel.classList.toggle("chart-panel-active", match);
      panel.classList.toggle("rank-panel-active", match);
      if (match) panel.removeAttribute("hidden");
      else panel.setAttribute("hidden", "");
    });
  }

  root.querySelectorAll("[data-scenario-tab]").forEach(function (tab) {
    tab.addEventListener("click", function () {
      scenario = tab.getAttribute("data-scenario-tab");
      sync();
    });
  });
  root.querySelectorAll("[data-os-btn]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      os = btn.getAttribute("data-os-btn");
      sync();
      btn.blur();
    });
  });
  root.querySelectorAll("[data-arch-btn]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      arch = btn.getAttribute("data-arch-btn");
      sync();
      btn.blur();
    });
  });
  root.querySelectorAll(".plat-side").forEach(function (side) {
    side.addEventListener("mouseleave", function () {
      var focused = side.querySelector(":focus");
      if (focused) focused.blur();
    });
  });

  sync();
})();
