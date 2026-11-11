import DokumentumKit
import SwiftUI
import UIKit

/// The share extension (plan of #4, part 4). It copies each shared PDF or image into the app group's share
/// queue (`ShareQueue`, from `DokumentumKit`, the only package it links) and closes on its own; the app imports
/// the items when it is opened next. It never opens the archive and never decodes an image (the extension's
/// memory limit). It asks nothing (PQ6): "Saving to Dokumentum…" while it copies, and only an error stays on
/// screen, with "OK". The extension does not log: the app's logging lives with the archive's package.
final class ShareViewController: UIViewController {
    private let sheet = ShareSheetState()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(
            rootView: ShareSheetView(state: sheet, done: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task {
            let notSaved = await ShareSaver.save(providers, to: ShareSaver.appQueue())
            if notSaved == 0 {
                finish()
            } else {
                sheet.failed = true
            }
        }
    }

    /// Ends the request. Items written before an error stay in the queue: the app imports them.
    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// What the sheet shows.
@MainActor @Observable
final class ShareSheetState {
    /// An attachment could not be saved; the sheet waits for "OK".
    var failed = false
}

/// The extension's small sheet: no title or tag questions (PQ6).
struct ShareSheetView: View {
    let state: ShareSheetState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if state.failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("This item cannot be saved")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("OK", action: done)
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text("Saving to Dokumentum…")
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
