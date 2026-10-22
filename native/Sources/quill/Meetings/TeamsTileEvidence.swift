import Foundation

/// Teams desktop exposes the remote video as an AXMenuItem, its name under
/// vdi-occlusion, and a separate frame overlay. The overlay gains
/// vdi-frame-occlusion while the speaking border is shown. Self video is an
/// AXImage and is deliberately excluded. Unknown layouts produce no tiles.
enum TeamsTileEvidence {
    static func members(_ nodes: [SpeakerUINode], localName: String?) -> [RosterMember] {
        var result: [RosterMember] = []
        for index in nodes.indices where nodes[index].classes.contains("vdi-occlusion") {
            let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: index, in: nodes) && !nodes[$0].text.isEmpty }
            guard names.count == 1, let nameIndex = names.first, let name = SpeakerAttribution.cleanName(nodes[nameIndex].text) else { continue }
            let local = SpeakerAttribution.isLocalName(name, localName: localName)
            if !result.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.is_local == local }) {
                result.append(RosterMember(name: name, is_local: local))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private static func descendant(_ index: Int, of ancestor: Int, in nodes: [SpeakerUINode]) -> Bool {
        var current = nodes[index].parent
        var visited: Set<Int> = []
        while let parent = current, nodes.indices.contains(parent), visited.insert(parent).inserted {
            if parent == ancestor { return true }
            current = nodes[parent].parent
        }
        return false
    }
    static func tiles(_ nodes: [SpeakerUINode]) -> [SpeakerUITile] {
        func descendant(_ index: Int, of ancestor: Int) -> Bool {
            Self.descendant(index, of: ancestor, in: nodes)
        }
        var result: [SpeakerUITile] = []
        for index in nodes.indices {
            let tile = nodes[index]
            guard tile.role == "AXMenuItem", tile.classes.contains("fui-Flex"),
                  tile.text.contains("Context menu is available"),
                  !tile.text.localizedCaseInsensitiveContains("pinned"),
                  !tile.text.localizedCaseInsensitiveContains("myself"),
                  !tile.text.localizedCaseInsensitiveContains("(you)") else { continue }
            let bars = nodes.indices.filter { nodes[$0].classes.contains("vdi-occlusion") && descendant($0, of: index) }
            guard bars.count == 1, let bar = bars.first else { continue }
            let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: bar) && SpeakerAttribution.cleanName(nodes[$0].text) != nil }
            let frames = nodes.indices.filter { nodes[$0].parent == index && nodes[$0].role == "AXGroup"
                && nodes[$0].subrole == "AXEmptyGroup" && nodes[$0].classes.contains("fui-Flex") }
            guard names.count == 1, let nameIndex = names.first, frames.count == 1, let frame = frames.first,
                  let name = SpeakerAttribution.cleanName(nodes[nameIndex].text) else { continue }
            result.append(SpeakerUITile(indicatorIndex: frame, nameIndex: nameIndex, name: name, isLocal: false, kind: .teamsFrame))
        }
        return result
    }
}
