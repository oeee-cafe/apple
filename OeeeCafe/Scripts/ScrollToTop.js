// macOS. Reselecting the page scrolls it back to the top. There is no scroll view to
// ask on the Mac, and on wide windows the site scrolls `main` rather than the page, so
// whichever of the two is scrolled goes back. The answer is whether either was.
(function () {
  var scrolled = [document.scrollingElement, document.querySelector("main.ds-content")]
    .filter(function (element) { return element && element.scrollTop > 1; });
  scrolled.forEach(function (element) { element.scrollTo({ top: 0, behavior: "smooth" }); });
  return scrolled.length > 0;
})();
