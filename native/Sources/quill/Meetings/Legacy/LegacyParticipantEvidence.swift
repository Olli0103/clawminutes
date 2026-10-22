import Foundation

// Fixture compatibility for inherited provider parsers. Runtime Teams roster
// extraction lives in TeamsTileEvidence. No provider is enabled here.
extension ParticipantEvidence {
    static func members(_ nodes: [SpeakerUINode], service: String, localName: String?) -> [RosterMember] {
        var result: [RosterMember] = []
        func add(_ raw: String, local: Bool = false) {
            let name = local && ["You", "Tu"].contains(raw) ? localName : raw
            guard let name = SpeakerAttribution.cleanName(name) else { return }
            let member = RosterMember(name: name, is_local: local || SpeakerAttribution.isLocalName(name, localName: localName))
            if !result.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.is_local == member.is_local }) { result.append(member) }
        }
        func descendant(_ index: Int, of ancestor: Int) -> Bool {
            var parent = nodes[index].parent
            var seen: Set<Int> = []
            while let next = parent, nodes.indices.contains(next), seen.insert(next).inserted {
                if next == ancestor { return true }
                parent = nodes[next].parent
            }
            return false
        }
        if service == "Google Meet" {
            // Names remain available on silent/camera-off tiles, even when a
            // speaking indicator is absent or its DOM structure changes.
            for index in nodes.indices where nodes[index].classes.contains("OFfHfd") {
                let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: index) && !nodes[$0].text.isEmpty }
                if names.count == 1, let name = names.first { add(nodes[name].text, local: nodes[index].classes.contains("eQJ1qd")) }
            }
        } else if service == "Microsoft Teams" {
            return TeamsTileEvidence.members(nodes, localName: localName)
        } else if service == "Slack" {
            for tile in SlackTileEvidence.tiles(nodes) { add(tile.name) }
        } else if service == "Zoom" {
            for node in nodes where node.roleDescription == "video render" {
                if let video = ZoomSpeakerEvidence.participant(description: node.text, frame: .zero, localName: localName) { add(video.name, local: video.isLocal) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

}
