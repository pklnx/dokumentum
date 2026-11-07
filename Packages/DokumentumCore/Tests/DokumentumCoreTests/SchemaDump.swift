import CoreData
import Foundation

/// The text form of a Core Data model that `Schema/schema-v<N>.txt` holds and
/// `scripts/check-schema-snapshots.py` reads. One line per entity and per property, sorted, so a diff
/// shows exactly what changed:
///
///     entity Document uniqueness=none
///     attribute Document.title type=string optional=no default="" external=no transient=no
///     relationship Document.tags to=Tag many=yes optional=yes inverse=documents delete=nullify ordered=no
///
/// `default=generated` marks a default SwiftData computes when it builds the model (`Date()`, `UUID()`), so
/// its value differs on every run; `default=none` means there is none.
enum SchemaDump {
    static func text(of model: NSManagedObjectModel, header: String) -> String {
        var lines = ["# \(header)"]
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let name = entity.name ?? "?"
            let uniqueness =
                entity.uniquenessConstraints.isEmpty
                ? "none"
                : entity.uniquenessConstraints.map { $0.map { "\($0)" }.joined(separator: "+") }.joined(separator: ",")
            lines.append("entity \(name) uniqueness=\(uniqueness)")
            for (propertyName, property) in entity.propertiesByName.sorted(by: { $0.key < $1.key }) {
                if let attribute = property as? NSAttributeDescription {
                    lines.append(
                        "attribute \(name).\(propertyName) type=\(typeName(attribute.attributeType)) "
                            + "optional=\(flag(attribute.isOptional)) default=\(defaultValue(attribute)) "
                            + "external=\(flag(attribute.allowsExternalBinaryDataStorage)) "
                            + "transient=\(flag(attribute.isTransient))")
                } else if let relationship = property as? NSRelationshipDescription {
                    lines.append(
                        "relationship \(name).\(propertyName) to=\(relationship.destinationEntity?.name ?? "none") "
                            + "many=\(flag(relationship.isToMany)) optional=\(flag(relationship.isOptional)) "
                            + "inverse=\(relationship.inverseRelationship?.name ?? "none") "
                            + "delete=\(deleteRule(relationship.deleteRule)) ordered=\(flag(relationship.isOrdered))")
                } else {
                    lines.append("other \(name).\(propertyName)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func flag(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func typeName(_ type: NSAttributeType) -> String {
        switch type {
        case .stringAttributeType: "string"
        case .booleanAttributeType: "bool"
        case .integer16AttributeType: "int16"
        case .integer32AttributeType: "int32"
        case .integer64AttributeType: "int64"
        case .doubleAttributeType: "double"
        case .floatAttributeType: "float"
        case .decimalAttributeType: "decimal"
        case .dateAttributeType: "date"
        case .UUIDAttributeType: "uuid"
        case .binaryDataAttributeType: "binary"
        case .URIAttributeType: "uri"
        case .transformableAttributeType: "transformable"
        default: "other(\(type.rawValue))"
        }
    }

    private static func defaultValue(_ attribute: NSAttributeDescription) -> String {
        guard let value = attribute.defaultValue else { return "none" }
        switch attribute.attributeType {
        case .stringAttributeType:
            let data = try? JSONEncoder().encode(value as? String ?? "")
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        case .booleanAttributeType:
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType, .doubleAttributeType,
            .floatAttributeType:
            return (value as? NSNumber)?.stringValue ?? "?"
        default:
            return "generated"
        }
    }

    private static func deleteRule(_ rule: NSDeleteRule) -> String {
        switch rule {
        case .noActionDeleteRule: "noAction"
        case .nullifyDeleteRule: "nullify"
        case .cascadeDeleteRule: "cascade"
        case .denyDeleteRule: "deny"
        @unknown default: "other(\(rule.rawValue))"
        }
    }
}
