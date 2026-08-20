import Foundation
import SwiftUI

/// The layout tree inside one tab. A tab starts as a single leaf and grows a
/// tree as the user splits; splitting is what turns a tab into a workspace.
indirect enum PaneNode: Identifiable, Hashable {
    case leaf(UUID)                                   // a session id
    case split(id: UUID, axis: SplitAxis, children: [PaneNode], fractions: [Double])

    var id: UUID {
        switch self {
        case .leaf(let sessionID):     return sessionID
        case .split(let id, _, _, _):  return id
        }
    }

    var sessionIDs: [UUID] {
        switch self {
        case .leaf(let id):                return [id]
        case .split(_, _, let children, _): return children.flatMap(\.sessionIDs)
        }
    }

    var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    /// Splits the leaf holding `target`, inserting `newSession` beside it.
    /// Splitting along the axis the pane is already divided by extends that
    /// split rather than nesting a new one, which is what keeps deep layouts sane.
    func splitting(_ target: UUID, with newSession: UUID, axis: SplitAxis) -> PaneNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(id: UUID(), axis: axis,
                          children: [.leaf(id), .leaf(newSession)],
                          fractions: [0.5, 0.5])

        case .split(let splitID, let splitAxis, let children, let fractions):
            guard sessionIDs.contains(target) else { return self }

            if splitAxis == axis,
               let index = children.firstIndex(where: { if case .leaf(let l) = $0 { return l == target } else { return false } }) {
                // Extend this split: give the new pane half of its neighbour's space.
                var newChildren = children
                var newFractions = fractions
                let share = newFractions[index] / 2
                newFractions[index] = share
                newChildren.insert(.leaf(newSession), at: index + 1)
                newFractions.insert(share, at: index + 1)
                return .split(id: splitID, axis: splitAxis, children: newChildren, fractions: newFractions)
            }

            let updated = children.map { $0.splitting(target, with: newSession, axis: axis) }
            return .split(id: splitID, axis: splitAxis, children: updated, fractions: fractions)
        }
    }

    /// Removes a pane, collapsing any split left with a single child so the
    /// tree never accumulates redundant one-child nodes.
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self

        case .split(let splitID, let axis, let children, let fractions):
            var newChildren: [PaneNode] = []
            var newFractions: [Double] = []
            for (index, child) in children.enumerated() {
                if let kept = child.removing(target) {
                    newChildren.append(kept)
                    newFractions.append(fractions[index])
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }

            // Re-normalise so the survivors absorb the freed space proportionally.
            let total = newFractions.reduce(0, +)
            if total > 0 { newFractions = newFractions.map { $0 / total } }
            return .split(id: splitID, axis: axis, children: newChildren, fractions: newFractions)
        }
    }

    func updatingFractions(splitID: UUID, to newFractions: [Double]) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let children, let fractions):
            if id == splitID {
                return .split(id: id, axis: axis, children: children, fractions: newFractions)
            }
            return .split(id: id, axis: axis,
                          children: children.map { $0.updatingFractions(splitID: splitID, to: newFractions) },
                          fractions: fractions)
        }
    }
}

enum SplitAxis: String, Codable, Hashable {
    case horizontal   // panes side by side
    case vertical     // panes stacked
}


// MARK: - Persistence

/// A pane tree with session *indices* instead of ids, so a layout can be saved
/// and rebuilt against freshly created sessions on the next launch.
indirect enum LayoutNode: Codable {
    case leaf(Int)
    case split(axis: SplitAxis, children: [LayoutNode], fractions: [Double])
}

extension PaneNode {
    /// - Parameter index: maps a session id to its position in the saved list.
    func snapshot(index: [UUID: Int]) -> LayoutNode? {
        switch self {
        case .leaf(let id):
            guard let position = index[id] else { return nil }
            return .leaf(position)

        case .split(_, let axis, let children, let fractions):
            var keptChildren: [LayoutNode] = []
            var keptFractions: [Double] = []
            for (offset, child) in children.enumerated() {
                // A pane whose session died is simply dropped from the snapshot.
                guard let encoded = child.snapshot(index: index) else { continue }
                keptChildren.append(encoded)
                keptFractions.append(offset < fractions.count ? fractions[offset] : 0)
            }
            guard !keptChildren.isEmpty else { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            return .split(axis: axis, children: keptChildren, fractions: keptFractions)
        }
    }

    /// - Parameter ids: session ids in the same order as the saved list.
    static func rebuild(from node: LayoutNode, ids: [UUID]) -> PaneNode? {
        switch node {
        case .leaf(let position):
            guard ids.indices.contains(position) else { return nil }
            return .leaf(ids[position])

        case .split(let axis, let children, let fractions):
            var keptChildren: [PaneNode] = []
            var keptFractions: [Double] = []
            for (offset, child) in children.enumerated() {
                guard let decoded = rebuild(from: child, ids: ids) else { continue }
                keptChildren.append(decoded)
                keptFractions.append(offset < fractions.count ? fractions[offset] : 0)
            }
            guard !keptChildren.isEmpty else { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            let total = keptFractions.reduce(0, +)
            if total > 0 { keptFractions = keptFractions.map { $0 / total } }
            return .split(id: UUID(), axis: axis, children: keptChildren, fractions: keptFractions)
        }
    }
}

/// What gets written to disk for one pane.
struct PaneSnapshot: Codable {
    var shellPath: String
    var workingDirectory: String?
    /// Identifies the shell inside the session daemon, so a relaunch can
    /// reattach to the running process instead of starting a new one.
    var persistentID: String?
}

struct TabSnapshot: Codable {
    var groupID: UUID?
    var customTitle: String?
    var panes: [PaneSnapshot]
    var layout: LayoutNode
    // Defaulted so a layout file written before pinning existed still decodes.
    var isPinned: Bool = false
    var isLocked: Bool = false
    var aiEnabled: Bool = true
}

struct WorkspaceSnapshot: Codable {
    var tabs: [TabSnapshot]
    var selectedIndex: Int?
}
