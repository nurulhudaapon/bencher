//! Browser bridge for chart PNG export (html-to-image).
//! Invoked from the Zig client component via zx.client.js → window.__benchSaveChart.

(function () {
  var busy = false;
  /** Transparent gutter around the card so the drop shadow is visible in the PNG. */
  var EXPORT_PAD = 24;

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
    var originalBoxShadow = root.style.boxShadow;
    var originalBorderRadius = root.style.borderRadius;
    var originalBackground = root.style.background;
    var githubEls = root.querySelectorAll(".github-info");
    var websiteUrl = root.querySelector(".website-url");
    var exportChrome = root.querySelectorAll(".export-chrome");
    var saveBtn = document.getElementById("save-png-btn");
    var shell = null;
    var parent = root.parentNode;
    var nextSibling = root.nextSibling;
    var barSnapshots = [];

    function settleBars() {
      // Snap bars to their final height so mid-animation frames are never exported.
      // Inline styles also copy into the html-to-image clone (CSS alone can re-trigger).
      root.querySelectorAll(".bar").forEach(function (bar) {
        barSnapshots.push({
          el: bar,
          animation: bar.style.animation,
          transform: bar.style.transform,
          opacity: bar.style.opacity,
        });
        bar.style.animation = "none";
        bar.style.transform = "none";
        bar.style.opacity = "0.92";
      });
    }

    function restoreBars() {
      barSnapshots.forEach(function (snap) {
        snap.el.style.animation = snap.animation;
        snap.el.style.transform = snap.transform;
        snap.el.style.opacity = snap.opacity;
      });
      barSnapshots = [];
    }

    function restore() {
      if (shell && shell.parentNode) {
        parent.insertBefore(root, nextSibling);
        shell.parentNode.removeChild(shell);
        shell = null;
      }
      restoreBars();
      root.style.overflow = originalOverflow;
      root.style.width = originalWidth;
      root.style.boxShadow = originalBoxShadow;
      root.style.borderRadius = originalBorderRadius;
      root.style.background = originalBackground;
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
        settleBars();

        root.style.width = "800px";
        root.style.overflow = "hidden";
        root.style.borderRadius = "0.85rem";
        root.style.background = "#121820";
        root.style.boxShadow = "0 16px 40px -12px rgba(0, 0, 0, 0.55)";

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

        // Padding on a wrapper (not the card) keeps a transparent gutter for the shadow.
        // Applying padding on #export-root itself fails under border-box: it insets content
        // instead of adding outer margin, so the PNG loses the soft edge.
        shell = document.createElement("div");
        shell.className = "export-shell";
        shell.style.cssText =
          "display:block;padding:" +
          EXPORT_PAD +
          "px;background:transparent;box-sizing:content-box;width:max-content;";
        parent.insertBefore(shell, root);
        shell.appendChild(root);

        return wait(100);
      })
      .then(function () {
        return import("https://esm.sh/html-to-image@1.11.13");
      })
      .then(function (mod) {
        return mod.toPng(shell, {
          cacheBust: true,
          pixelRatio: 2,
          backgroundColor: null,
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
