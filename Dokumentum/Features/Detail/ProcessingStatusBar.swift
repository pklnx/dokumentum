import DokumentumCore
import DokumentumKit
import SwiftUI

/// The open document's processing state, only in the detail (maintainer decision P2 on #6): one line for a document
/// that is pending, being processed, waiting for its suggestions (`classify`, #8 part 3) or failed, and for a failed
/// one a "Try again" button
/// (`LibraryModel.retryProcessing(of:)`). Nothing for a processed document or a state of a newer build; the list rows
/// show none of it.
///
/// The text is primary on the window's own background, not on a material, so its contrast is the system's in light
/// and dark (the audit fails text on `.bar` whatever its contrast, #74). The line is one VoiceOver element, the button
/// another.
struct ProcessingStatusBar: View {
    @Bindable var model: LibraryModel

    /// What the line says for each state; `nil` shows no line.
    enum Status: Equatable {
        case pending, processing, classify, failed

        init?(_ state: ProcessingState) {
            switch state {
            case .pending: self = .pending
            case .processing: self = .processing
            case .failed: self = .failed
            // Its text is there; the classification step (#8) suggests metadata, on this device or the other one.
            case .classify: self = .classify
            case .done, .unknown: return nil
            }
        }

        var text: LocalizedStringResource {
            switch self {
            case .pending: "Text recognition pending"
            case .processing: "Recognising text…"
            case .classify: "Suggesting metadata…"
            case .failed: "Text recognition failed"
            }
        }

        var systemImage: String {
            switch self {
            case .pending: "clock"
            case .processing: "text.viewfinder"
            case .classify: "sparkles"
            case .failed: "exclamationmark.triangle"
            }
        }

        var identifier: String {
            switch self {
            case .pending: AccessibilityID.detailProcessingPending
            case .processing: AccessibilityID.detailProcessingRunning
            case .classify: AccessibilityID.detailProcessingClassify
            case .failed: AccessibilityID.detailProcessingFailed
            }
        }
    }

    var body: some View {
        if let document = model.selectedDocument, let status = Status(document.processingState) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label {
                        Text(status.text)
                    } icon: {
                        Image(systemName: status.systemImage)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(status.identifier)
                    Spacer(minLength: 8)
                    // Not in the trash: a trashed document is not processed until it is restored (review N2 of #135).
                    if status == .failed, document.deletedAt == nil, model.canRetryProcessing {
                        Button("Try again") {
                            Task { await model.retryProcessing(of: document.instanceID) }
                        }
                        #if os(iOS)
                            // A bordered button with a primary label: the plain button's system blue on white is
                            // about 4:1, and the iPhone audit reported "Contrast nearly passed" on it.
                            .buttonStyle(.bordered)
                            .tint(.primary)
                        #endif
                        .disabled(model.retrying != nil)
                        .accessibilityIdentifier(AccessibilityID.detailProcessingRetry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.background)
        }
    }
}
