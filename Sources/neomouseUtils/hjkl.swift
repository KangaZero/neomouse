import CoreGraphics

// Pure mapping from a Vim-style direction key to a cursor delta. Kept free of
// CGEvent/AppKit so it can be unit-tested without an event tap or Accessibility
// permissions.
public enum HJKLDirection: Equatable {
    case left
    case down
    case up
    case right

    public init?(_ key: String) {
        switch key {
        case "h": self = .left
        case "j": self = .down
        case "k": self = .up
        case "l": self = .right
        default: return nil
        }
    }

    // CG coords: y increases downward, so .down returns +y.
    public func delta(stepX: CGFloat, stepY: CGFloat, count: CGFloat = 1) -> CGVector {
        switch self {
        case .left: return CGVector(dx: -stepX * count, dy: 0)
        case .down: return CGVector(dx: 0, dy: stepY * count)
        case .up: return CGVector(dx: 0, dy: -stepY * count)
        case .right: return CGVector(dx: stepX * count, dy: 0)
        }
    }
}
