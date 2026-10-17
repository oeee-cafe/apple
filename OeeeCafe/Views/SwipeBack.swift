#if os(iOS)
import UIKit
import WebKit

/// Back by a swipe to the right from anywhere on the page, as a reader's other apps go back:
/// the page follows the finger off to the right, over the page it goes back to, and goes if
/// let go far enough or fast enough. WebKit's own swipe starts only at the screen's edge, so
/// it is left the right edge, which is Forward, and its left edge is turned off: every back
/// swipe is this one, and they all feel the same.
///
/// A drag to the right is not a swipe back when it is the page's: a slider, a drawing zoomed
/// closer, a row scrolled along -- which the page says as the finger lands (`pressed`,
/// app_bridge.jinja in oeee-cafe/web) -- nor a press held before it moves, which is selecting
/// text or the long press on a drawing. In the painter it is a stroke, and this is off.
///
/// What shows under the page is a picture of the page underneath as it was left, taken as
/// each finger lands on it: much of the site goes from page to page without a load (htmx),
/// so the tap on a link is the last moment the page it leaves is known to be on screen. A page
/// left with no picture -- one not touched -- shows the site's ground instead.
final class SwipeBack: NSObject, UIGestureRecognizerDelegate {
    private weak var webView: WKWebView?
    private let pan = UIPanGestureRecognizer()

    /// Off in the painter (`showPageState`).
    var isEnabled = true {
        didSet { pan.isEnabled = isEnabled }
    }

    /// Whether the finger down now landed on something that takes a sideways drag itself, as
    /// the page said. Cleared as each finger lands, before the page has been told of it.
    var landedSideways = false

    /// When the finger down now landed.
    private var landedAt: TimeInterval = 0

    /// Pictures of pages as they were left, the newest last; a few, as WebKit keeps a few.
    private var pictures: [(item: WKBackForwardListItem, view: UIView)] = []
    private static let picturesKept = 4

    /// The swipe on screen, or the page gone back to that it covers until that page shows.
    private var stage: Stage?

    func install(on webView: WKWebView) {
        self.webView = webView
        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        // A finger: Apple Pencil on a page scrolls it, as it always has.
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        webView.addGestureRecognizer(pan)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pictures.removeAll() }
        }
    }

    /// Turns off WebKit's swipe from the left edge, leaving its swipe from the right, Forward.
    /// WebKit makes them afresh when its gestures are turned back on, so this follows each time.
    func leaveWebKitForward() {
        guard let webView else { return }
        for case let edge as UIScreenEdgePanGestureRecognizer in webView.gestureRecognizers ?? []
        where edge.edges.contains(.left) {
            edge.isEnabled = false
        }
    }

    // MARK: - Pictures

    /// Keeps a picture of the page on screen, for when it is gone back to.
    func keepPicture() {
        guard let webView, let item = webView.backForwardList.currentItem,
              let view = webView.snapshotView(afterScreenUpdates: false) else { return }
        pictures.removeAll { $0.item === item }
        pictures.append((item, view))
        if pictures.count > Self.picturesKept {
            pictures.removeFirst(pictures.count - Self.picturesKept)
        }
    }

    private func picture(of item: WKBackForwardListItem?) -> UIView? {
        guard let item else { return nil }
        return pictures.last { $0.item === item }?.view
    }

    // MARK: - Whether to begin

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        landedSideways = false
        landedAt = touch.timestamp
        if stage == nil { keepPicture() }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let webView, stage == nil, webView.canGoBack, !landedSideways else { return false }
        // Held before it moved: selecting text, or the drawing's menu.
        guard ProcessInfo.processInfo.systemUptime - landedAt < 0.5 else { return false }
        let moved = pan.translation(in: webView)
        guard moved.x > 0, moved.x > abs(moved.y) * 1.5 else { return false }
        // A page zoomed in, or a row scrolled along, has somewhere to go first.
        return !scrollsBack(at: pan.location(in: webView), in: webView)
    }

    /// Whether a scroll view under the finger -- the page's, or one of WebKit's for a box that
    /// scrolls -- is scrolled along, and so a drag to the right scrolls it back.
    private func scrollsBack(at point: CGPoint, in webView: WKWebView) -> Bool {
        var view = webView.hitTest(point, with: nil)
        while let current = view, current !== webView {
            if let scroller = current as? UIScrollView,
               scroller.contentOffset.x > -scroller.adjustedContentInset.left + 0.5 {
                return true
            }
            view = current.superview
        }
        return false
    }

    /// The page's touches and scrolling go on until the swipe is sure of itself.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: - The swipe

    @objc private func panned() {
        guard let webView else { return }
        switch pan.state {
        case .began:
            guard let container = webView.superview,
                  let page = webView.snapshotView(afterScreenUpdates: false) else {
                cancel()
                return
            }
            // The page stops scrolling under the finger: it is being moved, not read.
            webView.scrollView.panGestureRecognizer.isEnabled = false
            webView.scrollView.panGestureRecognizer.isEnabled = true
            let under = picture(of: webView.backForwardList.backItem) ?? ground()
            stage = Stage(over: webView, in: container, page: page, under: under)
        case .changed:
            stage?.follow(pan.translation(in: webView).x)
        case .ended:
            let along = pan.translation(in: webView).x
            let speed = pan.velocity(in: webView).x
            let width = webView.bounds.width
            if speed > 300 || (along > width / 2 && speed > -300) {
                stage?.finish(speed: speed) { [weak self] in self?.goBack() }
            } else {
                stage?.undo(speed: speed) { [weak self] in self?.stage = nil }
            }
        case .cancelled, .failed:
            stage?.undo(speed: 0) { [weak self] in self?.stage = nil }
        default:
            break
        }
    }

    private func cancel() {
        pan.isEnabled = false
        pan.isEnabled = isEnabled
    }

    private func ground() -> UIView {
        let view = UIView()
        view.backgroundColor = SiteTheme.ground(SiteTheme.shared.pageGround)
        return view
    }

    // MARK: - Arriving

    /// The page now under the finger is the one gone back to; the picture of it stays up until
    /// the page itself is there to take its place.
    private var leftPath: String?
    private var waiting: Task<Void, Never>?

    private func goBack() {
        guard let webView else { return }
        leftPath = webView.url?.path
        webView.goBack()
        // A page that takes long to come is shown coming rather than as a picture of it.
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.arrived()
        }
    }

    /// A page said what it is (WebController.pageSaid): if it is not the page left, the
    /// page gone back to is on screen.
    func pageSaid(path: String) {
        guard stage != nil, leftPath != nil, path != leftPath else { return }
        arrived()
    }

    /// WebKit finished loading a page, or failed to: the swipe's page is over either way.
    func loadEnded() {
        guard stage != nil, leftPath != nil else { return }
        arrived()
    }

    private func arrived() {
        waiting?.cancel()
        waiting = nil
        leftPath = nil
        // A frame for the page to paint under the picture before the picture goes.
        let stage = self.stage
        self.stage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            stage?.fadeAway()
        }
    }
}

/// What a swipe shows over the web view: the page being swiped away, and under it the page
/// it goes back to, a little behind and shaded, as a navigation controller's pages are.
private final class Stage {
    private let view = UIView()
    private let page: UIView
    private let under: UIView
    private let shade = UIView()
    private var width: CGFloat { view.bounds.width }

    init(over webView: WKWebView, in container: UIView, page: UIView, under: UIView) {
        self.page = page
        self.under = under
        view.frame = webView.frame
        view.clipsToBounds = true
        view.backgroundColor = SiteTheme.ground(SiteTheme.shared.pageGround)
        container.insertSubview(view, aboveSubview: webView)

        for layer in [under, shade, page] {
            layer.frame = view.bounds
            view.addSubview(layer)
        }
        shade.backgroundColor = .black
        page.layer.shadowColor = UIColor.black.cgColor
        page.layer.shadowOpacity = 0.2
        page.layer.shadowRadius = 8
        page.layer.shadowOffset = .zero
        page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
        follow(0)
    }

    func follow(_ along: CGFloat) {
        let along = min(max(along, 0), width)
        let left = width == 0 ? 1 : 1 - along / width
        page.transform = CGAffineTransform(translationX: along, y: 0)
        under.transform = CGAffineTransform(translationX: -width * 0.3 * left, y: 0)
        shade.alpha = 0.12 * left
    }

    func finish(speed: CGFloat, then done: @escaping () -> Void) {
        animate(to: width, speed: speed) { [page] in
            page.removeFromSuperview()
            done()
        }
    }

    func undo(speed: CGFloat, then done: @escaping () -> Void) {
        animate(to: 0, speed: speed) { [view] in
            view.removeFromSuperview()
            done()
        }
    }

    func fadeAway() {
        UIView.animate(withDuration: 0.15, animations: { self.view.alpha = 0 }) { _ in
            self.view.removeFromSuperview()
        }
    }

    /// Carries on at the finger's speed, as a navigation controller's pages do.
    private func animate(to target: CGFloat, speed: CGFloat, then done: @escaping () -> Void) {
        let from = page.transform.tx
        let distance = target - from
        let velocity = distance == 0 ? 0 : speed / distance
        let spring = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: velocity, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: spring)
        animator.addAnimations { self.follow(target) }
        animator.addCompletion { _ in done() }
        animator.startAnimation()
    }
}
#endif
