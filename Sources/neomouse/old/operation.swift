import CoreGraphics

struct FindOperation {
    var currentPendingOperation: String?
    var point: CGPoint
}

struct NormalOperation {
    var operation: String
}

enum Command {
    case numbers
    case relativenumbers
}

struct CommandOperation {
    var operation: Command
}
