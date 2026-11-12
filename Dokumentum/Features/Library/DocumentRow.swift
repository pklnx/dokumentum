import DokumentumCore
import DokumentumKit
import SwiftUI

/// One list row (PQ4): the title, or "Untitled document"; the document date; correspondent and type;
/// the tag names; in the trash, since when; the first page's thumbnail at the leading edge (#6, P1), decorative.
/// VoiceOver reads it as one sentence, without the thumbnail.
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
        HStack(alignment: .top, spacing: 10) {
            RowThumbnail(instanceID: document.instanceID)
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
                if let trashedSince {
                    Label {
                        Text(trashedSince)
                    } icon: {
                        Image(systemName: "trash")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var accessibilityLabel: String {
        let label = document.accessibilityLabel(
            displayTitle: title, tagPaths: tagPaths, strings: Self.accessibilityStrings)
        return trashedSince.map { "\(label), \(String(localized: $0))" } ?? label
    }

    /// "In the Trash since 7 Nov 2026" for a trashed document (plan of #3, part 4).
    private var trashedSince: LocalizedStringResource? {
        document.deletedAt.map { "In the Trash since \($0.formatted(date: .abbreviated, time: .omitted))" }
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
