#if os(iOS)
import UIKit

/// NEO's ground and its 14px grid, behind the page, for where the page does not reach.
///
/// The site draws the grid on the document (`html`, style.css in oeee-cafe/web), and a
/// document ends: past the last of a page scrolled to its foot is the strip the scroll view
/// keeps clear of the tab bar and the home indicator, and a page pulled past either end
/// shows what is behind it too. Plain ground there read as the pattern stopping short. So
/// the grid goes on under the page, and it is put in the scroll view with the page rather
/// than behind the web view: it moves as the page moves, with no catching up, and it is
/// laid from the document's corner, so its lines run on from the page's where the two meet.
final class PageGrid: UIView {
    /// The grid's cell, in the page's CSS pixels (`background-size`).
    static let cell: CGFloat = 14
    /// How far the grid runs past the document's edges, in whole cells so the grid keeps
    /// the document's phase: further than a page is ever pulled.
    private static let margin = cell * 100

    private weak var scrollView: UIScrollView?
    private var contentSize: NSKeyValueObservation?

    init(under scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        scrollView.insertSubview(self, at: 0)
        // The content size changes as the page grows and as it is zoomed, which is when the
        // grid has to be laid again; a scroll moves it with no help.
        contentSize = scrollView.observe(\.contentSize, options: [.initial]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lay() }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.paint()
        }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Covers the document and a margin around it, at the page's zoom.
    private func lay() {
        guard let scrollView else { return }
        let scale = scrollView.zoomScale
        let margin = Self.margin
        let width = max(scrollView.contentSize.width, scrollView.bounds.width) / scale + margin * 2
        let height = max(scrollView.contentSize.height, scrollView.bounds.height) / scale + margin * 2
        transform = CGAffineTransform(scaleX: scale, y: scale)
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        center = CGPoint(x: (width / 2 - margin) * scale, y: (height / 2 - margin) * scale)
        // Moved to the back again: WebKit adds views of its own to the scroll view.
        scrollView.sendSubviewToBack(self)
    }

    /// One cell: the ground, with a 1px line along its top and its left, as the site's two
    /// gradients draw it. Drawn again when the theme turns, a pattern colour being fixed.
    private func paint() {
        let traits = traitCollection
        let cell = Self.cell
        let tile = UIGraphicsImageRenderer(size: CGSize(width: cell, height: cell)).image { context in
            UIColor(named: "Ground")!.resolvedColor(with: traits).setFill()
            context.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
            UIColor(named: "Grid")!.resolvedColor(with: traits).setFill()
            context.fill(CGRect(x: 0, y: 0, width: cell, height: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: cell))
        }
        backgroundColor = UIColor(patternImage: tile)
    }
}
#endif
