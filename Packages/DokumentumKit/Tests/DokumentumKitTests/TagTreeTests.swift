import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

struct TagTreeTests {
    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    private static func tag(_ number: Int, _ name: String, parent: Int? = nil) -> TagRecord {
        TagRecord(instanceID: id(number), parentInstanceID: parent.map(id), name: name)
    }

    /// Builds the tree off the test's thread and waits for a signal, so a traversal that never ends
    /// fails the test at the safety net instead of hanging the run.
    private static func build(_ records: [TagRecord]) async -> TagTree? {
        let built = TestSignal()
        let box = Box()
        Task.detached {
            box.tree = TagTree(records)
            built.fire()
        }
        guard await built.wait(timeout: .seconds(20), "TagTree did not finish") else { return nil }
        return box.tree
    }

    private final class Box: @unchecked Sendable {
        // Written once by the builder before `built.fire()`, read after the wait.
        var tree: TagTree?
    }

    private func names(_ tree: TagTree, _ ids: [UUID]) -> [String] {
        ids.compactMap { tree.tags[$0]?.name }
    }

    @Test func nestsChildrenAndSortsSiblingsByName() {
        let tree = TagTree([
            Self.tag(1, "Tax"), Self.tag(2, "Auto"), Self.tag(3, "Werkstatt", parent: 4),
            Self.tag(4, "Golf", parent: 2), Self.tag(5, "Benzin", parent: 2), Self.tag(6, "important"),
        ])
        #expect(names(tree, tree.roots) == ["Auto", "important", "Tax"])
        #expect(names(tree, tree.children(of: Self.id(2))) == ["Benzin", "Golf"])
        #expect(names(tree, tree.children(of: Self.id(4))) == ["Werkstatt"])
    }

    @Test func equalNamesSortByInstanceID() {
        let tree = TagTree([Self.tag(9, "Tax"), Self.tag(3, "Tax")])
        #expect(tree.roots == [Self.id(3), Self.id(9)])
    }

    @Test func visibleRowsShowOnlyTheChildrenOfExpandedTags() {
        let tree = TagTree([Self.tag(1, "Auto"), Self.tag(2, "Golf", parent: 1), Self.tag(3, "Tax")])
        let collapsed = tree.visibleRows(expanded: [])
        #expect(collapsed.map(\.tag.name) == ["Auto", "Tax"])
        #expect(collapsed.map(\.hasChildren) == [true, false])
        let expanded = tree.visibleRows(expanded: [Self.id(1)])
        #expect(expanded.map(\.tag.name) == ["Auto", "Golf", "Tax"])
        #expect(expanded.map(\.depth) == [0, 1, 0])
    }

    @Test func aTagWhoseParentIsMissingIsARoot() {
        let tree = TagTree([Self.tag(1, "Golf", parent: 99), Self.tag(2, "Tax")])
        #expect(Set(tree.roots) == [Self.id(1), Self.id(2)])
        #expect(tree.displayPath(of: Self.id(1)) == "Golf")
        #expect(tree.ancestors(of: Self.id(1)).isEmpty)
    }

    @Test func aTwoCycleFinishesAndShowsItsMembersAsRoots() async throws {
        let tree = try #require(await Self.build([Self.tag(1, "A", parent: 2), Self.tag(2, "B", parent: 1)]))
        #expect(tree.roots == [Self.id(1), Self.id(2)])
        #expect(tree.children(of: Self.id(1)).isEmpty)
        #expect(tree.children(of: Self.id(2)).isEmpty)
        #expect(tree.visibleRows(expanded: [Self.id(1), Self.id(2)]).map(\.tag.name) == ["A", "B"])
        #expect(tree.displayPath(of: Self.id(1)) == "B › A")
        #expect(tree.subtreeIDs(of: Self.id(1)) == [Self.id(1), Self.id(2)])
    }

    @Test func aThreeCycleAndTheTagBelowItFinishAndShowAsRoots() async throws {
        let tree = try #require(
            await Self.build([
                Self.tag(1, "A", parent: 3), Self.tag(2, "B", parent: 1), Self.tag(3, "C", parent: 2),
                Self.tag(4, "D", parent: 1), Self.tag(5, "Root"), Self.tag(6, "Child", parent: 5),
            ]))
        #expect(names(tree, tree.roots) == ["A", "B", "C", "D", "Root"])
        #expect(names(tree, tree.children(of: Self.id(5))) == ["Child"])
        #expect(tree.ancestors(of: Self.id(1)) == [Self.id(3), Self.id(2)])
        #expect(tree.subtreeIDs(of: Self.id(2)) == [Self.id(1), Self.id(2), Self.id(3), Self.id(4)])
        #expect(tree.displayPath(of: Self.id(4)) == "B › C › A › D")
    }

    @Test func aSelfParentFinishesAndIsARoot() async throws {
        let tree = try #require(await Self.build([Self.tag(1, "A", parent: 1)]))
        #expect(tree.roots == [Self.id(1)])
        #expect(tree.displayPath(of: Self.id(1)) == "A")
        #expect(tree.subtreeIDs(of: Self.id(1)) == [Self.id(1)])
    }

    @Test func aChainTenThousandDeepFinishes() async throws {
        let depth = 10_000
        let records = (0..<depth).map { Self.tag($0, "T\($0)", parent: $0 == 0 ? nil : $0 - 1) }
        let tree = try #require(await Self.build(records.reversed()))
        #expect(tree.roots == [Self.id(0)])
        #expect(tree.ancestors(of: Self.id(depth - 1)).count == depth - 1)
        #expect(tree.subtreeIDs(of: Self.id(0)).count == depth)
        let all = Set(records.map(\.instanceID))
        #expect(tree.visibleRows(expanded: all).count == depth)
    }

    @Test func theSubtreeIncludesGrandchildren() {
        let tree = TagTree([
            Self.tag(1, "Auto"), Self.tag(2, "Golf", parent: 1), Self.tag(3, "Werkstatt", parent: 2),
            Self.tag(4, "Tax"),
        ])
        #expect(tree.subtreeIDs(of: Self.id(1)) == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(tree.subtreeIDs(of: Self.id(2)) == [Self.id(2), Self.id(3)])
        #expect(tree.subtreeIDs(of: Self.id(4)) == [Self.id(4)])
        #expect(tree.subtreeIDs(of: Self.id(99)).isEmpty)
    }

    @Test func theDisplayPathJoinsTheNamesFromTheTop() {
        let tree = TagTree([
            Self.tag(1, "Auto"), Self.tag(2, "Golf", parent: 1), Self.tag(3, "Werkstatt", parent: 2),
        ])
        #expect(TagTree.separator == " › ")
        #expect(tree.displayPath(of: Self.id(3)) == "Auto › Golf › Werkstatt")
        #expect(tree.displayPath(of: Self.id(1)) == "Auto")
        #expect(tree.displayPath(of: Self.id(99)) == "")
    }

    @Test func aRepeatedInstanceIDKeepsItsFirstRecord() {
        let tree = TagTree([Self.tag(1, "First"), Self.tag(1, "Second")])
        #expect(tree.roots == [Self.id(1)])
        #expect(tree.tags[Self.id(1)]?.name == "First")
    }
}
