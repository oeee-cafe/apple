// macOS, at the start of every page. Tells the site where it is, makes room for the
// traffic lights, and lets the toolbar's empty space drag the window (SiteChrome in
// SiteView.swift). This is the app's own chrome, not something the site says, so it
// stays on a channel of its own (`oeeeWindow`) rather than the site's bridge.
(function () {
  var root = document.documentElement;
  root.setAttribute("data-desktop", "macos");
  var style = document.createElement("style");
  style.textContent = 'html[data-desktop="macos"] .nav-bar #menubar { padding-left: 96px; }';
  (document.head || root).appendChild(style);
  // The toolbar is the title bar: a press on its empty space moves the window, and a
  // double click zooms it. Its links, buttons and fields stay the page's.
  window.addEventListener("mousedown", function (event) {
    if (event.button !== 0 || event.defaultPrevented) return;
    var target = event.target;
    if (!target || !target.closest || !target.closest(".nav-bar")) return;
    if (target.closest("a, button, input, select, textarea, label, summary, details, [role], [contenteditable], [tabindex], [hx-get], [hx-post]")) return;
    event.preventDefault();
    window.webkit.messageHandlers.oeeeWindow.postMessage({ window: event.detail === 2 ? "zoom" : "drag" });
  });
})();
