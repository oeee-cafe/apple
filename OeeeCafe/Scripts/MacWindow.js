// macOS, at the start of every page. Lets the toolbar's empty space drag the window
// (SiteChrome in SiteView.swift). The site marks the root `data-desktop="macos"` itself,
// from the web view's user agent, and keeps the room for the traffic lights (theme_head.jinja
// and ds.css in oeee-cafe/web); it marks what may move the window `data-window-drag`
// (toolbar.jinja). Moving the window is the app's own chrome, not something the site says,
// so it stays on a channel of its own (`oeeeWindow`) rather than the site's bridge.
(function () {
  // The toolbar is the title bar: a press on its empty space moves the window, and a
  // double click zooms it. Its links, buttons and fields stay the page's.
  window.addEventListener("mousedown", function (event) {
    if (event.button !== 0 || event.defaultPrevented) return;
    var target = event.target;
    if (!target || !target.closest || !target.closest("[data-window-drag]")) return;
    if (target.closest("a, button, input, select, textarea, label, summary, details, [role], [contenteditable], [tabindex], [hx-get], [hx-post]")) return;
    event.preventDefault();
    window.webkit.messageHandlers.oeeeWindow.postMessage({ window: event.detail === 2 ? "zoom" : "drag" });
  });
})();
