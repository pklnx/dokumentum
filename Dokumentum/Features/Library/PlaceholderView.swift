import SwiftUI

#if os(macOS)
    /// A Mac placeholder for an empty list or detail ("No document selected", "Inbox empty", "Still downloading"), in
    /// place of `ContentUnavailableView` (#82; maintainer decisions P1 and P2). The system view draws its title and its
    /// description in the secondary colour, 3.11:1 and 3.95:1 on white in light mode, and gives VoiceOver its symbol
    /// and title as one element, which the Mac audit judges as a whole ("Contrast failed"). Here the title (#82, P1)
    /// and the description (#89, maintainer decision of 2026-11-11) are in the primary colour, and the title is the
    /// element with the identifier; the symbol is decoration, hidden from VoiceOver. Fonts and spacings, and the
    /// symbol's tertiary colour, are those of `ContentUnavailableView` on macOS 27, measured by rendering both views
    /// with the app's strings in English and German, so only the colours of the title and the description change. The
    /// iPhone keeps `ContentUnavailableView`, whose title is already primary there.
    struct PlaceholderView: View {
        let title: LocalizedStringKey
        let systemImage: String
        var description: Text?
        /// On the title: the element that UI tests and the audit find. The description gets `<identifier>.description`.
        var identifier: String?

        var body: some View {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                titleText
                    .font(.system(size: 15, weight: .bold))
                    .lineSpacing(1)
                    .foregroundStyle(.primary)
                    .padding(.top, 24)
                if let description {
                    // The system view's font and spacing, in the primary colour (#89).
                    descriptionText(description)
                        .font(.system(size: 15))
                        .lineSpacing(1)
                        .foregroundStyle(.primary)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        @ViewBuilder
        private var titleText: some View {
            if let identifier {
                Text(title).accessibilityIdentifier(identifier)
            } else {
                Text(title)
            }
        }

        @ViewBuilder
        private func descriptionText(_ description: Text) -> some View {
            if let identifier {
                description.accessibilityIdentifier("\(identifier).description")
            } else {
                description
            }
        }
    }
#endif
