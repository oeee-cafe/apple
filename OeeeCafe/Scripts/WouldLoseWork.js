// Whether the page would stop a browser from leaving it: its own `beforeunload`
// handlers, asked the way a browser asks them. WKWebView asks none of them, so a
// drawing would go without a word. The painter answers only for a drawing with
// something in it, and not while it is being saved.
//
// Evaluated, not injected: the answer is the value of this expression.
(function () {
  var event;
  try {
    event = document.createEvent("BeforeUnloadEvent");
    event.initEvent("beforeunload", false, true);
  } catch (_) {
    event = new Event("beforeunload", { cancelable: true });
  }
  window.dispatchEvent(event);
  return event.defaultPrevented ||
    (typeof event.returnValue === "string" && event.returnValue !== "");
})();
