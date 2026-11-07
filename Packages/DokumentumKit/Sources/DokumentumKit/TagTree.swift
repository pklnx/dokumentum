import Foundation

/// A tag as the sidebar needs it: its own `instanceID`, its parent's, and its name.
public struct TagRecord: Sendable, Hashable, Identifiable {
    public let instanceID: UUID
    public let parentInstanceID: UUID?
    public let name: String

    public var id: UUID { instanceID }

    public init(instanceID: UUID, parentInstanceID: UUID?, name: String) {
        self.instanceID = instanceID
        self.parentInstanceID = parentInstanceID
        self.name = name
    }
}

/// Nested tags ("Auto › Golf") as the sidebar shows them, built from plain values. Ported from the
/// predecessor's `TagHierarchy` (pklnx/document-archive, `Services/TagHierarchy.swift`), on IDs
/// instead of models.
///
/// The input can be anything sync delivers, so no input can hang or crash it:
/// - A tag whose parent is not among the records (not synced yet, or a tombstone the caller left
///   out) is a root.
/// - Members of a parent cycle, and the tags below one, are roots without children, as in the
///   predecessor, until a repair breaks the cycle. No tag disappears.
/// - Every traversal is iterative and keeps a visited set: deep chains do not overflow the stack and
///   cycles end.
///
/// A document keeps only the tags chosen for it; a tag's filter and count include its subtree when
/// reading (the predecessor's rule).
public struct TagTree: Sendable {
    /// Between the names of a display path, as in the predecessor.
    public static let separator = " › "

    /// One visible row of the tree: the tag and its indentation.
    public struct Row: Sendable, Hashable, Identifiable {
        public let tag: TagRecord
        public let depth: Int
        public let hasChildren: Bool
        public var id: UUID { tag.instanceID }
    }

    /// Every tag by `instanceID`. A repeated `instanceID` keeps its first record.
    public let tags: [UUID: TagRecord]
    /// The roots of the shown tree, sorted by name.
    public let roots: [UUID]
    /// The shown children of each tag, sorted by name. Only tags whose chain reaches a root have any.
    private let shownChildren: [UUID: [UUID]]
    /// The children by the parent each tag names, whether or not its chain reaches a root: what the
    /// filter's subtree follows, as the predecessor's `descendants(of:)` did.
    private let declaredChildren: [UUID: [UUID]]

    public init(_ records: [TagRecord]) {
        var tags: [UUID: TagRecord] = [:]
        var order: [UUID] = []
        for record in records where tags[record.instanceID] == nil {
            tags[record.instanceID] = record
            order.append(record.instanceID)
        }
        let rooted = Self.rootedTags(tags, order: order)
        var shown: [UUID: [UUID]] = [:]
        var declared: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        for id in order {
            let parent = tags[id]?.parentInstanceID.flatMap { tags[$0] == nil ? nil : $0 }
            if let parent { declared[parent, default: []].append(id) }
            if let parent, rooted.contains(id) {
                shown[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
        self.tags = tags
        self.roots = Self.sortedByName(roots, in: tags)
        self.shownChildren = shown.mapValues { Self.sortedByName($0, in: tags) }
        self.declaredChildren = declared
    }

    /// The tags whose parent chain ends at a root (no parent, or a parent that is not among the
    /// records). One pass: each walk stops at a tag whose answer is known, so a chain is walked once.
    private static func rootedTags(_ tags: [UUID: TagRecord], order: [UUID]) -> Set<UUID> {
        var known: [UUID: Bool] = [:]
        for start in order where known[start] == nil {
            var path: [UUID] = []
            var onPath: Set<UUID> = []
            var current: UUID? = start
            var answer = true
            while let id = current {
                if let value = known[id] {
                    answer = value
                    break
                }
                guard onPath.insert(id).inserted else {
                    answer = false  // a cycle: it and everything walked into it never reach a root
                    break
                }
                path.append(id)
                current = tags[id]?.parentInstanceID.flatMap { tags[$0] == nil ? nil : $0 }
            }
            for id in path { known[id] = answer }
        }
        return Set(known.filter(\.value).keys)
    }

    /// The shown children of a tag, sorted by name.
    public func children(of id: UUID) -> [UUID] {
        shownChildren[id] ?? []
    }

    /// The parent, its parent and so on, nearest first. Stops before a tag already seen, so a cycle
    /// gives each member once and never the tag itself. A parent that is not among the records ends
    /// the chain.
    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = [id]
        var current = tags[id]?.parentInstanceID
        while let next = current, tags[next] != nil, seen.insert(next).inserted {
            result.append(next)
            current = tags[next]?.parentInstanceID
        }
        return result
    }

    /// "Auto › Golf": the names from the top down to the tag. Empty for an unknown tag.
    public func displayPath(of id: UUID) -> String {
        guard tags[id] != nil else { return "" }
        return (ancestors(of: id).reversed() + [id]).compactMap { tags[$0]?.name }
            .joined(separator: Self.separator)
    }

    /// The tag and every tag below it: what the tag's filter and count include. Follows the parent
    /// each tag names, with a visited set, so the members of a cycle include each other.
    public func subtreeIDs(of id: UUID) -> Set<UUID> {
        guard tags[id] != nil else { return [] }
        var result: Set<UUID> = [id]
        var queue = declaredChildren[id] ?? []
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            guard result.insert(next).inserted else { continue }
            queue.append(contentsOf: declaredChildren[next] ?? [])
        }
        return result
    }

    /// The rows to show, depth first: the children of expanded tags only.
    public func visibleRows(expanded: Set<UUID>) -> [Row] {
        var result: [Row] = []
        var stack = roots.reversed().map { ($0, 0) }
        while let (id, depth) = stack.popLast() {
            guard let tag = tags[id] else { continue }
            let children = children(of: id)
            result.append(Row(tag: tag, depth: depth, hasChildren: !children.isEmpty))
            if expanded.contains(id) {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    /// Alphabetical, as in the predecessor; equal names by `instanceID`, so the order is the same on
    /// every run and device.
    public static func sortedByName(_ ids: [UUID], in tags: [UUID: TagRecord]) -> [UUID] {
        ids.sorted { lhs, rhs in
            let left = tags[lhs]?.name ?? ""
            let right = tags[rhs]?.name ?? ""
            switch left.localizedStandardCompare(right) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.uuidString < rhs.uuidString
            }
        }
    }
}
