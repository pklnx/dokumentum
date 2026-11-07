import DokumentumCore
import Foundation
import PhotosUI
import SwiftUI

/// One photo picked in Photos; tests stub it.
protocol ImportPhotoItem: Sendable {
    /// The photo's bytes as Photos hands them over; `nil` or an error when it cannot (not downloaded).
    func loadData() async throws -> Data?
}

extension PhotosPickerItem: ImportPhotoItem {
    /// The bytes in the encoding the picker was asked for: `.current` keeps the photo as stored, so the same
    /// photo hashes the same the next time (T10). The type it came as goes to the log, no content.
    func loadData() async throws -> Data? {
        let data = try await loadTransferable(type: Data.self)
        let type = supportedContentTypes.first?.identifier ?? "none"
        Log.importing.notice(
            "Photo handed over: \(data?.count ?? 0, privacy: .public) bytes, type \(type, privacy: .public)")
        return data
    }
}
