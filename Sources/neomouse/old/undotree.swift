import Foundation

class UndoNode {
    let id: UUID
    var content: String  // full buffer state (or a diff)
    var parent: UndoNode?
    var children: [UndoNode] = []
    var timestamp: Date
    var isCurrent: Bool = false

    init(content: String, parent: UndoNode?) {
        self.id = UUID()
        self.content = content
        self.parent = parent
        self.timestamp = Date()
    }
}
class UndoTree {
    var root: UndoNode
    var current: UndoNode

    init(initialContent: String) {
        root = UndoNode(content: initialContent, parent: nil)
        current = root
        current.isCurrent = true
    }

    // called on every edit
    func record(_ content: String) {
        current.isCurrent = false
        let node = UndoNode(content: content, parent: current)
        current.children.append(node)
        current = node
        current.isCurrent = true
    }

    // standard undo — walk up to parent
    func undo() -> String? {
        guard let parent = current.parent else { return nil }
        current.isCurrent = false
        current = parent
        current.isCurrent = true
        return current.content
    }

    // redo — walk to last visited child (like nvim default)
    func redo() -> String? {
        guard let child = current.children.last else { return nil }
        current.isCurrent = false
        current = child
        current.isCurrent = true
        return current.content
    }

    // jump to any arbitrary node (the undotree panel feature)
    func jump(to node: UndoNode) -> String {
        current.isCurrent = false
        current = node
        current.isCurrent = true
        return current.content
    }
}
