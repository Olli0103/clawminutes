import AppKit
import ApplicationServices

/// The enabled provider contract. Display names and browser titles cannot admit
/// another process into Accessibility scanning.
struct MeetingApp: Sendable {
    let pid: pid_t
    let name: String
    let service: String?
    var processStartedAt: Double? = nil
    var bundleIdentifier: String? = nil

    var isSupported: Bool {
        service == "Microsoft Teams" && ["com.microsoft.teams2", "com.microsoft.teams"].contains(bundleIdentifier?.lowercased() ?? "")
    }
    @MainActor static func running() -> [MeetingApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let candidate = MeetingApp(pid: app.processIdentifier, name: app.localizedName ?? "Teams",
                service: "Microsoft Teams", processStartedAt: app.launchDate?.timeIntervalSince1970,
                bundleIdentifier: app.bundleIdentifier)
            guard candidate.isSupported, app.activationPolicy == .regular else { return nil }
            return candidate
        }
    }
}

struct MeetingScan: Sendable {
    var observations: [String: MeetingObservation] = [:]
    var contexts: [String: MeetingContext] = [:]
    var needsPermission = false
    var speakers: [String: [String]] = [:]
    var speakerObservedAt: [String: Double] = [:]
    var speakerCaptureStatus: [String: String] = [:]
    var speakerBoxes: [String: [[String: String]]] = [:]
    var observedAt = Date().timeIntervalSince1970
    var rosters: [SpeakerObservation] = []
}

/// Teams desktop Accessibility adapter. No browser or other provider runtime is
/// created here. Values cross the actor; Accessibility objects stay on it.
actor MeetingScanner {
    private struct Known {
        let meeting: DetectedMeeting
        let pid: pid_t
        let window: AXUIElement
        var cgWindowID: UInt32? = nil
    }
    private struct Node {
        let element: AXUIElement
        let role: String
        let text: String
        let activeSpeaker: String?
        let parentIndex: Int?
        let classNames: [String]
        let subrole: String
    }
    private struct Window {
        let element: AXUIElement
        var nodes: [Node]
        let complete: Bool
        let startedAt: Double
        let endedAt: Double
    }
    private var known: [String: Known] = [:]
    private var contexts: [String: MeetingContext] = [:]
    private var serial = 0
    private var enabledAccessibility: Set<pid_t> = []
    private var endedSince: [String: TimeInterval] = [:]
    private var endState = MeetingEndState()
    private struct CachedTile {
        let indicator: AXUIElement
        let nameElement: AXUIElement
        let name: String
        let isLocal: Bool
    }
    private var tiles: [String: [CachedTile]] = [:]
    private var rosters: [String: SpeakerObservation] = [:]
    private var speakerRefresh: [String: SpeakerTreeRefresh<AXUIElement>] = [:]
    private let permissionGranted: @Sendable () -> Bool
    init(permissionGranted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.permissionGranted = permissionGranted
    }

    func speakerActivity(for meetingID: String) async -> SpeakerObservation? {
        guard let entry = known[meetingID], permissionGranted(), !bool(entry.window, kAXMinimizedAttribute) else { return nil }
        refreshSpeakerTiles(entry)
        guard speakerRefresh[meetingID]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true,
              let cached = tiles[meetingID], !cached.isEmpty else { return nil }
        let started = Date().timeIntervalSince1970
        var names: [String] = []
        let localName = Config.localSpeakerName()
        for tile in cached {
            let currentName = SpeakerAttribution.cleanName(string(tile.nameElement, kAXValueAttribute))
            guard !isDestroyed(tile.indicator), currentName == tile.name else {
                invalidateSpeakerTiles(meetingID); return nil
            }
            let classes = Set(strings(tile.indicator, "AXDOMClassList"))
            guard classes.contains("fui-Flex") else { invalidateSpeakerTiles(meetingID); return nil }
            guard !tile.isLocal, !SpeakerAttribution.isLocalName(tile.name, localName: localName) else { continue }
            if classes.contains("vdi-frame-occlusion") { names.append(tile.name) }
        }
        let ended = Date().timeIntervalSince1970
        guard ended - started <= 0.2 else { return nil }
        return SpeakerObservation(observed_at: (started + ended) / 2, meeting_id: meetingID,
                                  names: Array(Set(names)).sorted(), source: "meeting_tile")
    }

    private func invalidateSpeakerTiles(_ id: String) {
        tiles.removeValue(forKey: id); rosters.removeValue(forKey: id)
        speakerRefresh[id]?.invalidate()
    }

    private func refreshSpeakerTiles(_ entry: Known) {
        let id = entry.meeting.id
        let root = entry.window
        guard !isDestroyed(root) else { invalidateSpeakerTiles(id); return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = now + 0.04
        var refresh = speakerRefresh[id] ?? SpeakerTreeRefresh<AXUIElement>()
        let snapshot = refresh.step(root: root, now: now, hasTime: { ProcessInfo.processInfo.systemUptime < deadline }) { element, parent in
            let role = string(element, kAXRoleAttribute)
            guard !role.isEmpty, let descendants = children(element, attribute: kAXChildrenAttribute) else { return nil }
            var text = ""
            if role == kAXStaticTextRole { text = string(element, kAXValueAttribute) }
            else if ["AXMenuItem", "AXButton", "AXTab", "AXHeading", "AXTabGroup", "AXCell"].contains(role) {
                let title = string(element, kAXTitleAttribute), description = string(element, kAXDescriptionAttribute)
                text = title == description || description.isEmpty ? title : (title.isEmpty ? description : title + " " + description)
                if ["AXTabGroup", "AXCell"].contains(role), !description.isEmpty { text = description }
                if ["AXButton", "AXTab", "AXHeading"].contains(role), !title.isEmpty, !description.isEmpty, title != description { text = title + "\n" + description }
            }
            let node = SpeakerUINode(parent: parent, role: role, text: text,
                                     classes: Set(strings(element, "AXDOMClassList")),
                                     subrole: role == "AXGroup" ? string(element, kAXSubroleAttribute) : "",
                                     roleDescription: "")
            return (node, descendants)
        }
        speakerRefresh[id] = refresh
        if !refresh.isFresh(at: now) {
            tiles.removeValue(forKey: id)
            rosters.removeValue(forKey: id)
        }
        guard let snapshot else { return }
        let nodes = snapshot.map(\.node)
        let members = TeamsTileEvidence.members(nodes, localName: Config.localSpeakerName())
        let count = ParticipantEvidence.participantCount(nodes)
        let complete = count == members.filter { !$0.is_local }.count + 1 && Config.localSpeakerName() != nil
        rosters[id] = SpeakerObservation(observed_at: Date().timeIntervalSince1970, meeting_id: id, names: [],
            source: "meeting_roster", participants: members, participant_count: count, roster_complete: complete)
        tiles[id] = TeamsTileEvidence.tiles(nodes).map {
            CachedTile(indicator: snapshot[$0.indicatorIndex].element, nameElement: snapshot[$0.nameIndex].element,
                       name: $0.name, isLocal: $0.isLocal)
        }
    }

    func scan(apps: [MeetingApp], captureSpeakers: Bool = false, inspectBoxes: Bool = false) -> MeetingScan {
        var result = MeetingScan()
        let apps = apps.filter(\.isSupported)
        let pids = Set(apps.map(\.pid))
        enabledAccessibility.formIntersection(pids)
        for entry in known.values where !pids.contains(entry.pid) { result.observations[entry.meeting.id] = .ended }
        // Reject foreign inputs before permission checks or any AX tree access.
        guard !apps.isEmpty else { return finish(result) }
        guard permissionGranted() else { result.needsPermission = true; return result }
        for app in apps {
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            if enabledAccessibility.insert(app.pid).inserted {
                AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            guard let elements = children(root, attribute: kAXWindowsAttribute) else { continue }
            let windows = elements.map { readTree($0) }
            for window in windows where hasCallControls(window) && !window.nodes.contains(where: { MeetingEvidence.isEndMessage($0.text) }) {
                let existing = known.values.first { $0.pid == app.pid && CFEqual($0.window, window.element) }
                let id = existing?.meeting.id ?? nextID(pid: app.pid)
                let time = Date().timeIntervalSince1970
                let title = TeamsMeetingTitle.clean(string(window.element, kAXTitleAttribute))
                var context = contexts[id] ?? MeetingContext(meeting_id: id, title: title ?? "Teams meeting", title_source: title == nil ? "unavailable" : "teams_window", first_observed_at: time, last_observed_at: time)
                context.observeActive(at: time)
                if let title { context.title = title; context.title_source = "teams_window" }
                contexts[id] = context; result.contexts[id] = context
                let windowID = existing?.cgWindowID ?? windowNumber(pid: app.pid, window: window.element)
                let consentIdentity = app.processStartedAt.map { MeetingConsentIdentity(processID: app.pid, processStartedAt: $0, windowID: windowID, title: title) }
                known[id] = Known(meeting: DetectedMeeting(id: id, app: app.name, service: "Microsoft Teams", consentIdentity: consentIdentity),
                                  pid: app.pid, window: window.element, cgWindowID: windowID)
            }
            for entry in known.values where entry.pid == app.pid {
                guard let window = windows.first(where: { CFEqual($0.element, entry.window) }) else {
                    result.observations[entry.meeting.id] = MeetingEvidence.missingWindow(meeting: entry.meeting,
                        replacementCall: windows.contains { hasCallControls($0) }, destroyed: isDestroyed(entry.window),
                        knownWindowID: entry.cgWindowID, currentWindowIDs: windowNumbers(pid: entry.pid))
                    continue
                }
                let leave = hasCallControls(window)
                let ended = window.nodes.contains { MeetingEvidence.isEndMessage($0.text) }
                if captureSpeakers && !ended {
                    refreshSpeakerTiles(entry)
                    if let roster = rosters[entry.meeting.id], speakerRefresh[entry.meeting.id]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true {
                        result.rosters.append(roster)
                    }
                }
                if captureSpeakers && !ended && !bool(entry.window, kAXMinimizedAttribute) {
                    let snapshot = inspectBoxes ? readTree(entry.window, readClasses: true) : window
                    let nodes = snapshot.nodes
                    let captureStarted = snapshot.startedAt, observedEnd = snapshot.endedAt
                    result.speakerCaptureStatus[entry.meeting.id] = "\(nodes.count) nodes"
                    result.speakers[entry.meeting.id] = observedEnd - captureStarted <= 0.8 ? Array(Set(nodes.compactMap(\.activeSpeaker))).sorted() : []
                    result.speakerObservedAt[entry.meeting.id] = (captureStarted + observedEnd) / 2
                    if inspectBoxes {
                        result.speakerBoxes[entry.meeting.id] = nodes.prefix(700).enumerated().map { index, node in
                            var value: CFTypeRef?
                            AXUIElementCopyAttributeValue(node.element, "AXDOMClassList" as CFString, &value)
                            var row: [String: String] = ["index": String(index), "parent": node.parentIndex.map(String.init) ?? "", "role": node.role, "text": String(node.text.prefix(160)),
                                                        "classes": (value as? [String] ?? []).joined(separator: " ")]
                            row["identifier"] = string(node.element, "AXIdentifier")
                            row["help"] = String(string(node.element, kAXHelpAttribute).prefix(200))
                            row["description"] = String(string(node.element, kAXDescriptionAttribute).prefix(200))
                            row["value"] = String(string(node.element, kAXValueAttribute).prefix(200))
                            row["subrole"] = string(node.element, kAXSubroleAttribute)
                            row["role_description"] = string(node.element, kAXRoleDescriptionAttribute)
                            row["title"] = String(string(node.element, kAXTitleAttribute).prefix(200))
                            if row["role_description"] == "Video render" {
                                var attributes: CFArray?
                                if AXUIElementCopyAttributeNames(node.element, &attributes) == .success {
                                    row["attribute_names"] = (attributes as? [String] ?? []).joined(separator: " ")
                                }
                                for attribute in ["AXSelected", "AXFocused", "AXValue", "AXExpanded", "AXEnabled", "AXCustomContent"] {
                                    var raw: CFTypeRef?
                                    if AXUIElementCopyAttributeValue(node.element, attribute as CFString, &raw) == .success, let raw {
                                        if let number = raw as? NSNumber { row[attribute] = number.stringValue }
                                        else if let text = raw as? String { row[attribute] = String(text.prefix(300)) }
                                    }
                                }
                            }
                            var sizeValue: CFTypeRef?
                            if AXUIElementCopyAttributeValue(node.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                               let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                                var size = CGSize.zero
                                if AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) { row["size"] = "\(size.width),\(size.height)" }
                            }
                            return row
                        }
                    }
                    let tileCount = tiles[entry.meeting.id]?.count ?? 0
                    result.speakerCaptureStatus[entry.meeting.id, default: ""] += "; \(tileCount) speaker tiles; discovery \(speakerRefresh[entry.meeting.id]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true ? "current" : "refreshing")"
                }
                // Missing controls are unknown. Only positive end evidence latches.
                result.observations[entry.meeting.id] = endState.observation(for: entry.meeting, inCall: leave, endScreen: ended && !leave)
            }
        }
        return finish(result)
    }

    private func finish(_ input: MeetingScan) -> MeetingScan {
        var result = input
        let now = ProcessInfo.processInfo.systemUptime
        for (id, observation) in result.observations {
            if observation == .ended {
                invalidateSpeakerTiles(id)
                speakerRefresh.removeValue(forKey: id)
                if endedSince[id] == nil { endedSince[id] = now }
                // Longer than the stop countdown; never prune uncertain meetings.
                if now - (endedSince[id] ?? now) > 120 {
                    known.removeValue(forKey: id)
                    endedSince.removeValue(forKey: id)
                    endState.forget(id)
                }
            } else { endedSince.removeValue(forKey: id) }
        }
        for (id, observation) in result.observations where observation == .ended {
            if var context = contexts[id] {
                if context.ended_observed_at == nil { context.ended_observed_at = Date().timeIntervalSince1970 }
                contexts[id] = context; result.contexts[id] = context
            }
        }
        result.observedAt = Date().timeIntervalSince1970
        return result
    }

    private func hasCallControls(_ window: Window) -> Bool {
        MeetingEvidence.hasCallControls(window.nodes.filter { $0.role == kAXButtonRole }.map(\.text))
    }

    private func nextID(pid: pid_t) -> String {
        serial += 1
        return "\(pid):\(serial)"
    }

    private func readTree(_ window: AXUIElement, readClasses: Bool = false) -> Window {
        let startedAt = Date().timeIntervalSince1970
        var nodes: [Node] = []
        var queue: [(AXUIElement, Int?)] = [(window, nil)]
        var visited: Set<CFHashCode> = []
        var complete = true
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while let (element, parentIndex) = queue.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard nodes.count < 2500, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                break
            }
            let role = string(element, kAXRoleAttribute)
            guard !role.isEmpty else { complete = false; continue }
            let description = string(element, kAXDescriptionAttribute)
            let title = string(element, kAXTitleAttribute)
            var text = [title, description].filter { !$0.isEmpty }.joined(separator: " ")
            if title == description { text = title }
            if role == kAXStaticTextRole { text = string(element, kAXValueAttribute) }
            let activeSpeaker = SpeakerEvidence.activeName(label: description, role: role)
                ?? SpeakerEvidence.activeName(label: title, role: role)
            nodes.append(Node(element: element, role: role, text: text, activeSpeaker: activeSpeaker,
                              parentIndex: parentIndex, classNames: readClasses ? strings(element, "AXDOMClassList") : [],
                              subrole: string(element, kAXSubroleAttribute)))
            if let childElements = children(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: childElements.reversed().map { ($0, nodes.count - 1) })
            } else { complete = false }
        }
        return Window(element: window, nodes: nodes, complete: complete,
                      startedAt: startedAt, endedAt: Date().timeIntervalSince1970)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let url = value as? URL { return url.absoluteString }
        return String((value as? String ?? "").prefix(2000))
    }

    private func strings(_ element: AXUIElement, _ attribute: String) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func windowInventory() -> [[String: Any]]? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              !rows.isEmpty else { return nil }
        return rows
    }
    private func windowNumbers(pid: pid_t) -> Set<UInt32>? {
        windowInventory().map { rows in Set(rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }) }
    }
    private func windowNumber(pid: pid_t, window: AXUIElement) -> UInt32? {
        guard let rect = frame(window), let rows = windowInventory() else { return nil }
        let matches: [UInt32] = rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let other = CGRect(dictionaryRepresentation: bounds),
                  abs(other.minX - rect.minX) < 2, abs(other.minY - rect.minY) < 2,
                  abs(other.width - rect.width) < 2, abs(other.height - rect.height) < 2 else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isDestroyed(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    private func children(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if attribute == kAXWindowsAttribute && error != .success { return nil }
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }
}
