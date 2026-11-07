import SwiftData

/// Every schema version and the stages between them. Every store opens through this plan.
///
/// **Rules for later versions** (docs/development/index.md, "Data model and sync"):
/// - Only `.lightweight(fromVersion:toVersion:)` stages: CloudKit accepts additive changes only, and a
///   custom stage would run on each device separately.
/// - A conversion of synced data is a one-time pass behind a flag, run after the store opened, never a
///   custom stage.
/// - A version is added only with a real model change: two versions with identical models have the same
///   checksum, which SwiftData rejects.
public enum DokumentumMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DokumentumSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
