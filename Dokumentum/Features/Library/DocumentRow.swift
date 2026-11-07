import DokumentumCore
import DokumentumKit
import SwiftUI

/// One list row (PQ4): the title, or "Untitled document"; the document date; correspondent and type;
/// the tag names. No thumbnail until step 5. VoiceOver reads it as one sentence.
struct DocumentRow: View {
    let document: LibraryDocument
    /// The display paths of the document's tags, sorted.
    let tagPaths: [String]

    private var title: String {
        displayTitle(document.title, fallback: String(localized: "Untitled document"))
    }

    private var metadata: String {
        [document.correspondent?.name, document.documentType?.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(document.documentDate, format: .dateTime.day().month().year())
                if !metadata.isEmpty {
                    Text(verbatim: metadata)
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !tagPaths.isEmpty {
                Label {
                    Text(verbatim: tagPaths.joined(separator: ", "))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "tag")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var accessibilityLabel: String {
        document.accessibilityLabel(displayTitle: title, tagPaths: tagPaths, strings: Self.accessibilityStrings)
    }

    /// The words of the VoiceOver label, localized here: Kit emits no strings.
    static var accessibilityStrings: LibraryDocument.AccessibilityStrings {
        LibraryDocument.AccessibilityStrings(
            date: { $0.formatted(date: .long, time: .omitted) },
            tags: { paths in
                let list = paths.formatted(.list(type: .and))
                return String(localized: "tags: \(list)")
            },
            inInbox: String(localized: "in inbox"))
    }
}
