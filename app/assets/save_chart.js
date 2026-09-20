//! Browser bridge for chart PNG export (html-to-image).
//! Invoked from the Zig client component via zx.client.js → window.__benchSaveChart.

(function () {
  var busy = false;

  function setBusy(on) {
    busy = on;
    var btn = document.getElementById("save-png-btn");
    if (!btn) return;
    btn.disabled = on;
    btn.classList.toggle("save-png-btn-busy", on);
    var idle = btn.querySelector("[data-save-idle]");
    var busyEl = btn.querySelector("[data-save-busy]");
    if (idle) idle.hidden = on;
    if (busyEl) busyEl.hidden = !on;
  }

  function nextPaint() {
    return new Promise(function (resolve) {
      requestAnimationFrame(function () {
        requestAnimationFrame(resolve);
      });
    });
  }

  function wait(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  window.__benchSaveChart = function () {
    if (busy) return;
    var root = document.getElementById("export-root");
    if (!root) return;

    setBusy(true);

    // Cover the page first so layout tweaks for export are not visible.
    var overlay = document.createElement("div");
    overlay.className = "export-loading-overlay";
    overlay.setAttribute("aria-live", "polite");
    overlay.setAttribute("aria-busy", "true");
    overlay.innerHTML =
      '<div class="export-loading-card"><span class="export-loading-spin"></span><span>Generating image...</span></div>';
    document.body.appendChild(overlay);
    document.body.classList.add("export-busy");

    var originalOverflow = root.style.overflow;
    var originalWidth = root.style.width;
    var githubEls = root.querySelectorAll(".github-info");
    var websiteUrl = root.querySelector(".website-url");
    var exportChrome = root.querySelectorAll(".export-chrome");
    var saveBtn = document.getElementById("save-png-btn");

    function restore() {
      root.style.overflow = originalOverflow;
      root.style.width = originalWidth;
      githubEls.forEach(function (el) {
        el.style.display = el.getAttribute("data-export-prev-display") || "";
        el.removeAttribute("data-export-prev-display");
      });
      exportChrome.forEach(function (el) {
        el.style.display = el.getAttribute("data-export-prev-display") || "";
        el.removeAttribute("data-export-prev-display");
      });
      if (websiteUrl) {
        var prev = websiteUrl.getAttribute("data-export-prev-display");
        websiteUrl.style.display = prev && prev.length ? prev : "none";
        websiteUrl.removeAttribute("data-export-prev-display");
      }
      if (saveBtn) saveBtn.style.visibility = "";
      document.body.classList.remove("export-busy");
      if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
      setBusy(false);
    }

    nextPaint()
      .then(function () {
        return wait(50);
      })
      .then(function () {
        root.style.overflow = "hidden";
        root.style.width = "800px";

        githubEls.forEach(function (el) {
          el.setAttribute("data-export-prev-display", el.style.display || "");
          el.style.display = "none";
        });
        exportChrome.forEach(function (el) {
          el.setAttribute("data-export-prev-display", el.style.display || "");
          el.style.display = "none";
        });
        if (websiteUrl) {
          websiteUrl.setAttribute("data-export-prev-display", websiteUrl.style.display || "");
          websiteUrl.style.display = "flex";
        }
        if (saveBtn) saveBtn.style.visibility = "hidden";

        return wait(100);
      })
      .then(function () {
        return import("https://esm.sh/html-to-image@1.11.13");
      })
      .then(function (mod) {
        var width = root.offsetWidth;
        var height = root.offsetHeight;
        return mod.toPng(root, {
          cacheBust: true,
          pixelRatio: 2,
          backgroundColor: null,
          width: width + 32,
          height: height + 32,
          style: {
            padding: "16px",
            overflow: "visible",
            width: width + "px",
            height: height + "px",
          },
          filter: function (node) {
            if (!node.classList) return true;
            return !node.classList.contains("export-loading-overlay");
          },
        });
      })
      .then(function (dataUrl) {
        var link = document.createElement("a");
        link.download =
          "zig-web-frameworks-benchmark-" + new Date().toISOString().split("T")[0] + ".png";
        link.href = dataUrl;
        link.click();
        restore();
      })
      .catch(function (err) {
        console.error("Failed to save chart:", err);
        restore();
      });
  };
})();
