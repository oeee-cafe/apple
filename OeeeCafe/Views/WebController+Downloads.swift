import WebKit
import UniformTypeIdentifiers
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file the page hands over rather than shows: the painter's, a draft's and a
/// collaborative session's PNG, saved as a link to a blob clicked with `download`
/// (drawingUpload.ts in oeee-cafe/web), and anything the site sends as an attachment.
///
/// The site leaves these to WKDownload (app_polyfills.jinja), which does nothing until the
/// app turns a navigation into one and says where the file goes. On the Mac that is a Save
/// panel, as a browser with "Ask where to save" would show. On iOS there is no folder to
/// ask about, so the file goes to a temporary one and the share sheet opens on it, where
/// Save Image and Save to Files are.
extension WebController: WKDownloadDelegate {
    /// Whether a response is a file to keep rather than a page: one the site marks as an
    /// attachment, or one WebKit cannot show.
    static func isDownload(_ response: WKNavigationResponse) -> Bool {
        if !response.canShowMIMEType { return true }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return disposition?.lowercased().hasPrefix("attachment") ?? false
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        if let type = UTType(filenameExtension: (suggestedFilename as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        #else
        // A folder of its own for each, so the file keeps the name the page gave it.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger.app.error("Failed to make a folder for a download: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let destination = folder.appendingPathComponent(name)
        downloadDestinations[ObjectIdentifier(download)] = destination
        return destination
        #endif
    }

    func downloadDidFinish(_ download: WKDownload) {
        #if os(iOS)
        guard let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        offer(file)
        #endif
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        #if os(iOS)
        if let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        Haptics.play("error")
        #endif
        Logger.network.error("Failed to download a file: \(error.localizedDescription, privacy: .public)")
    }

    #if os(iOS)
    /// The share sheet on the file, which goes once the sheet does: whatever the reader
    /// chose has its own copy by then.
    private func offer(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard let presenter = webView.presenter else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0
        )
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: folder)
        }
        presenter.present(sheet, animated: true)
    }
    #endif
}
