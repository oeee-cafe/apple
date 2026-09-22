// iOS. The painter zooms its canvas itself, but only for a pinch that starts on the
// canvas or the ground around it. One that starts anywhere else -- a room's chat, whose
// log scrolls -- reached WebKit and zoomed the whole page, panels and all. A drawing app
// does not do that, so its page is held at its own scale; WKWebView honours the limits
// that Safari overrides.
(function () {
  var meta = document.querySelector('meta[name="viewport"]');
  if (!meta) {
    meta = document.createElement("meta");
    meta.name = "viewport";
    document.head.appendChild(meta);
  }
  meta.content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no";
})();
