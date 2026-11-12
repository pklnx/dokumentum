import CoreGraphics
import SwiftUI

/// Where a list row's thumbnail comes from (#6, part 4): the library's source, and the library's `revision`, so a
/// thumbnail that has not arrived is looked for again each time the library reads again. Not set: the row shows the
/// placeholder and loads nothing (the Mac list's hidden measuring copy, #81).
struct RowThumbnails {
    let load: @Sendable (UUID) async -> CGImage?
    let revision: Int
}

extension EnvironmentValues {
    @Entry var rowThumbnails: RowThumbnails?
}

/// The miniature of a document's first page at the leading edge of its list row (maintainer decision P1 on #6), on
/// the iPhone and the Mac: a fixed 40 × 56 pt, so the row's height never depends on the image or on whether it has
/// arrived (the Mac list measures rows by a hidden copy, #81). A neutral placeholder until the thumbnail is there.
/// Decorative: hidden from VoiceOver, the row reads its sentence as before.
struct RowThumbnail: View {
    static let size = CGSize(width: 40, height: 56)

    let instanceID: UUID
    @Environment(\.rowThumbnails) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (instanceID: UUID, image: CGImage)?

    private struct LoadKey: Hashable {
        let instanceID: UUID
        let revision: Int?
    }

    var body: some View {
        ZStack {
            if let loaded, loaded.instanceID == instanceID {
                Image(decorative: loaded.image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        Rectangle().strokeBorder(.separator, lineWidth: 0.5)
                    }
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.25))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
        .task(id: LoadKey(instanceID: instanceID, revision: thumbnails?.revision)) {
            guard let thumbnails else { return }
            // A thumbnail never changes once it exists: one that is shown stays.
            if let loaded, loaded.instanceID == instanceID { return }
            guard let image = await thumbnails.load(instanceID), !Task.isCancelled else { return }
            loaded = (instanceID, image)
        }
    }
}
