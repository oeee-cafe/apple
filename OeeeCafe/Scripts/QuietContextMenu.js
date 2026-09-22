// macOS. The browser's own right-click menu -- Back, Reload, Open in New Window -- is
// the plainest sign that a window is a browser, so it is kept to text fields, a
// selection and images. Anywhere else a right click does nothing, unless the page has
// its own use for it, as the painter does.
window.addEventListener("contextmenu", function (event) {
  if (event.defaultPrevented) return;
  var target = event.target;
  if (target && target.closest) {
    if (target.closest("input, textarea, select, [contenteditable]")) return;
    if (target.closest("img")) return;
  }
  if (window.getSelection && String(window.getSelection()) !== "") return;
  event.preventDefault();
});
