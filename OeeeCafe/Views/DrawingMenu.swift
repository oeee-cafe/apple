#if os(iOS)
import UIKit
import WebKit
import Photos
import UniformTypeIdentifiers
import os

/// The menu a long press on a drawing opens: the drawing itself as the preview, and what
/// the Photos app offers for a picture -- Save to Photos, Copy, Share -- with the post's link
/// when the drawing is one. The site lets the press through only on drawings (ds.css, in
/// oeee-cafe/web); everything else on its pages has no callout.
///
/// WebKit names the link a long press was on but not the image, and while it is working
/// out the press the page cannot be asked: the answer would come after the finger had
/// lifted. So the site says which drawing a finger is on as it lands (`pressed`,
/// SiteBridge), and the menu is built from that, in the words the page last said
/// (SiteWords).
enum DrawingMenu {
    /// A pressed drawing. The menu has to answer while the finger is still down, so it is
    /// built from what the page knows at once, and the file follows.
    final class Drawing {
        let url: URL
        let link: URL?
        let size: CGSize
        private let referrer: URL?
        private var loading: Task<(Data, UTType, UIImage)?, Never>?

        init(url: URL, link: URL?, size: CGSize, referrer: URL?) {
            self.url = url
            self.link = link
            self.size = size
            self.referrer = referrer
        }

        /// Starts fetching the file, once the menu is actually opening: a finger landing on
        /// a drawing is usually the start of a scroll.
        func load() {
            guard loading == nil else { return }
            let url = url, referrer = referrer
            loading = Task {
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
                request.setValue(referrer?.absoluteString, forHTTPHeaderField: "Referer")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let image = UIImage(data: data) else { return nil }
                return (data, response.mimeType.flatMap { UTType(mimeType: $0) } ?? .png, image)
            }
        }

        /// The file, its type and the picture, once they have arrived.
        var file: (Data, UTType, UIImage)? {
            get async {
                load()
                return await loading?.value
            }
        }
    }

    /// The drawing a finger landed on, from what the page said.
    static func drawing(from pressed: SiteMessage.Drawing, referrer: URL?) -> Drawing? {
        guard let url = URL(string: pressed.src) else { return nil }
        return Drawing(
            url: url,
            link: pressed.link.isEmpty ? nil : URL(string: pressed.link),
            size: CGSize(width: pressed.width, height: pressed.height),
            referrer: referrer
        )
    }

    static func configuration(for drawing: Drawing, in webView: WKWebView) -> UIContextMenuConfiguration {
        drawing.load()
        let room = webView.window?.bounds.size ?? webView.bounds.size
        let words = SiteWords.current
        return UIContextMenuConfiguration(identifier: nil) {
            Preview(drawing: drawing, room: CGSize(width: room.width - 32, height: room.height * 0.6))
        } actionProvider: { _ in
            var actions = [
                UIAction(title: words.saveImage, image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    save(drawing)
                },
                UIAction(title: words.copyImage, image: UIImage(systemName: "doc.on.doc")) { _ in
                    Task {
                        guard let (data, type, _) = await drawing.file else { return }
                        UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
                    }
                },
                UIAction(title: words.share, image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    share(drawing, from: webView)
                },
            ]
            if let link = drawing.link {
                actions.append(UIAction(title: words.copyLink, image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = link
                })
            }
            return UIMenu(children: actions)
        }
    }

    /// Saved as the file it is, so a pixel drawing keeps its pixels rather than being
    /// re-encoded as a photo.
    private static func save(_ drawing: Drawing) {
        Task {
            guard let (data, type, _) = await drawing.file else {
                Haptics.play("error")
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Haptics.play("error")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = type.identifier
                    request.addResource(with: .photo, data: data, options: options)
                }
                Haptics.play("success")
            } catch {
                Logger.app.error("Failed to save a drawing to Photos: \(error.localizedDescription, privacy: .public)")
                Haptics.play("error")
            }
        }
    }

    private static func share(_ drawing: Drawing, from webView: WKWebView) {
        Task {
            guard let (_, _, image) = await drawing.file, var presenter = webView.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            var items: [Any] = [image]
            if let link = drawing.link {
                items.append(link)
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = webView
            sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
            presenter.present(sheet, animated: true)
        }
    }

    /// The drawing, as large as the screen allows, its pixels kept square rather than
    /// smoothed: most drawings are pixel art at a few hundred pixels across.
    private final class Preview: UIViewController {
        private let drawing: Drawing

        init(drawing: Drawing, room: CGSize) {
            self.drawing = drawing
            super.init(nibName: nil, bundle: nil)
            let size = drawing.size
            if size.width > 0, size.height > 0 {
                let scale = min(room.width / size.width, room.height / size.height)
                preferredContentSize = CGSize(width: size.width * scale, height: size.height * scale)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func loadView() {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.layer.magnificationFilter = .nearest
            imageView.backgroundColor = .white
            view = imageView
            Task { [weak imageView, drawing] in
                guard let (_, _, image) = await drawing.file, let imageView else { return }
                UIView.transition(with: imageView, duration: 0.15, options: .transitionCrossDissolve) {
                    imageView.image = image
                }
            }
        }
    }
}

/// What a press feels like: the site's controls name one (`haptic`, SiteBridge), and the
/// app's own actions use the same names.
enum Haptics {
    static func play(_ name: String) {
        switch name {
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        case "success":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }
}
#endif
