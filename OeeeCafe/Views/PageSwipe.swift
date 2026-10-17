#if os(iOS)
import UIKit
import WebKit

/// Back by a swipe to the right from anywhere on the page, as a reader's other apps go back,
/// and Forward by a swipe to the left from the screen's right edge, as Safari goes forward:
/// the page follows the finger, over or under the page it goes to, and goes if let go far
/// enough or fast enough.
///
/// Both are this app's, and WebKit's own swipes are off (`allowsBackForwardNavigationGestures`).
/// WebKit's starts only at the screen's edge, and with it on, a swipe from the left edge was
/// both at once -- WebKit's page and this one moving together.
///
/// A drag to the right is not a swipe back when it is the page's: a slider, a drawing zoomed
/// closer, a row scrolled along -- which the page says as the finger lands (`pressed`,
/// app_bridge.jinja in oeee-cafe/web) -- nor a press held before it moves, which is selecting
/// text or the long press on a drawing. In the painter it is a stroke, and this is off.
///
/// What shows of the page gone to is a picture of it as it was left, taken as each finger
/// lands: much of the site goes from page to page without a load (htmx), so the tap on a link
/// is the last moment the page it leaves is known to be on screen. A page left with no
/// picture -- one not touched -- shows the site's ground instead.
final class PageSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var webView: WKWebView?
    private let pan = UIPanGestureRecognizer()

    /// Off in the painter (`showPageState`).
    var isEnabled = true {
        didSet { pan.isEnabled = isEnabled }
    }

    /// Whether the finger down now landed on something that takes a sideways drag itself, as
    /// the page said. Cleared as each finger lands, before the page has been told of it.
    var landedSideways = false

    /// When and where the finger down now landed.
    private var landedAt: TimeInterval = 0
    private var landedX: CGFloat = 0

    /// How far in from the right edge a swipe forward starts, as Safari's does.
    private static let forwardEdge: CGFloat = 24

    /// Pictures of pages as they were left, the newest last; a few, as WebKit keeps a few.
    private var pictures: [(item: WKBackForwardListItem, view: UIView)] = []
    private static let picturesKept = 4

    /// The swipe on screen, or the page gone to that it covers until that page shows.
    private var stage: Stage?
    private var direction = Stage.Direction.back

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

    // MARK: - Pictures

    /// Keeps a picture of the page on screen, for when it is gone back or forward to.
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
        landedX = touch.location(in: webView).x
        if stage == nil { keepPicture() }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let webView, stage == nil else { return false }
        // Held before it moved: selecting text, or the drawing's menu.
        guard ProcessInfo.processInfo.systemUptime - landedAt < 0.5 else { return false }
        let moved = pan.translation(in: webView)
        guard abs(moved.x) > abs(moved.y) * 1.5 else { return false }
        if moved.x > 0 {
            guard webView.canGoBack, !landedSideways else { return false }
            // A page zoomed in, or a row scrolled along, has somewhere to go first.
            guard !scrollsBack(at: pan.location(in: webView), in: webView) else { return false }
            direction = .back
        } else {
            guard webView.canGoForward, landedX > webView.bounds.width - Self.forwardEdge else { return false }
            direction = .forward
        }
        return true
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
        let along = pan.translation(in: webView).x * direction.sign
        let speed = pan.velocity(in: webView).x * direction.sign
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
            let list = webView.backForwardList
            let other = picture(of: direction == .back ? list.backItem : list.forwardItem) ?? ground()
            stage = Stage(direction, over: webView, in: container, page: page, other: other)
        case .changed:
            stage?.follow(along)
        case .ended:
            let width = webView.bounds.width
            if speed > 300 || (along > width / 2 && speed > -300) {
                stage?.finish(speed: speed) { [weak self] in self?.go() }
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

    /// The page now on screen is a picture of the one gone to, which stays up until the page
    /// itself has been painted under it: once WebKit has committed to it, or, for a page the
    /// site changed to without a load (htmx), once the address is its and nothing is loading.
    /// Not when WebKit finishes loading, which waits for every image on the page; and not
    /// when the page says what it is, which a page the back-forward cache kept does not say
    /// again.
    private var leftURL: URL?
    private var addressChanged: NSKeyValueObservation?
    private var waiting: Task<Void, Never>?

    private func go() {
        guard let webView else { return }
        leftURL = webView.url
        addressChanged = webView.observe(\.url) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, webView.url != self.leftURL, !webView.isLoading else { return }
                self.painted()
            }
        }
        if direction == .back {
            webView.goBack()
        } else {
            webView.goForward()
        }
        // A page that takes long to come is shown coming rather than as a picture of it.
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.arrived()
        }
    }

    /// WebKit committed to a page (WebController+Navigation): the one gone to.
    func committed() {
        guard leftURL != nil else { return }
        painted()
    }

    /// A load that failed leaves the page that was there: nothing more is coming.
    func loadFailed() {
        guard leftURL != nil else { return }
        arrived()
    }

    /// Waits for the page gone to to be painted -- two frames of its own, the first of which
    /// may come before anything is drawn -- in a world of the app's, apart from the site's.
    private func painted() {
        guard let webView else { return }
        addressChanged = nil
        Task { [weak self] in
            _ = try? await webView.callAsyncJavaScript(
                "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));",
                arguments: [:], in: nil, contentWorld: .defaultClient
            )
            self?.arrived()
        }
    }

    private func arrived() {
        guard leftURL != nil else { return }
        waiting?.cancel()
        waiting = nil
        addressChanged = nil
        leftURL = nil
        let stage = self.stage
        self.stage = nil
        stage?.fadeAway()
    }
}

/// What a swipe shows over the web view, as a navigation controller shows its pages: going
/// back, the page slides off to the right over the one before it, which waits a little to the
/// left and shaded; going forward, the page after slides in from the right over this one.
private final class Stage {
    enum Direction {
        case back, forward

        /// Which way along the screen the finger goes to get there.
        var sign: CGFloat { self == .back ? 1 : -1 }
    }

    private let direction: Direction
    private let view = UIView()
    /// The page that moves with the finger, and the one that waits under it.
    private let top: UIView
    private let under: UIView
    private let shade = UIView()
    private var width: CGFloat { view.bounds.width }

    /// `page` is the page on screen, and `other` the one being gone to.
    init(_ direction: Direction, over webView: WKWebView, in container: UIView, page: UIView, other: UIView) {
        self.direction = direction
        (top, under) = direction == .back ? (page, other) : (other, page)
        view.frame = webView.frame
        view.clipsToBounds = true
        view.backgroundColor = SiteTheme.ground(SiteTheme.shared.pageGround)
        container.insertSubview(view, aboveSubview: webView)

        for layer in [under, shade, top] {
            // A picture is kept and shown again, and it keeps where the last swipe left it:
            // a frame set through a transform lands that far out.
            layer.transform = .identity
            layer.frame = view.bounds
            view.addSubview(layer)
        }
        shade.backgroundColor = .black
        top.layer.shadowColor = UIColor.black.cgColor
        top.layer.shadowOpacity = 0.2
        top.layer.shadowRadius = 8
        top.layer.shadowOffset = .zero
        top.layer.shadowPath = UIBezierPath(rect: top.bounds).cgPath
        follow(0)
    }

    /// How far the finger has gone, toward the page gone to.
    private var along: CGFloat = 0

    func follow(_ along: CGFloat) {
        self.along = min(max(along, 0), width)
        // How far over the page on top is: all the way over the one under it at rest.
        let over = width == 0 ? 1 : (direction == .back ? 1 - self.along / width : self.along / width)
        top.transform = CGAffineTransform(translationX: width * (1 - over), y: 0)
        under.transform = CGAffineTransform(translationX: -width * 0.3 * over, y: 0)
        shade.alpha = 0.12 * over
    }

    func finish(speed: CGFloat, then done: @escaping () -> Void) {
        animate(to: width, speed: speed) { [direction, top, under, shade] in
            // What stays is the page gone to.
            (direction == .back ? top : under).removeFromSuperview()
            shade.removeFromSuperview()
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
        let distance = target - along
        let velocity = distance == 0 ? 0 : speed / distance
        let spring = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: velocity, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: spring)
        animator.addAnimations { self.follow(target) }
        animator.addCompletion { _ in done() }
        animator.startAnimation()
    }
}
#endif
