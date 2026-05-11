import AppKit

enum GestureType {
    case magnify, smartMagnify, rotate, swipe

    var subtype: Int64 {
        switch self {
        case .magnify: return 8
        case .smartMagnify: return 9
        case .rotate: return 5
        case .swipe: return 6
        }
    }
}

func postGestureEvent(
    src: CGEventSource?,
    type: GestureType,
    value: Double,
    phase: CGGesturePhase,
    at point: CGPoint,
    dx: Double = 0,
    dy: Double = 0
) {
    guard let event = CGEvent(source: src) else { return }
    event.type = CGEventType(rawValue: 29)!  // kCGEventGesture
    event.location = point
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: type.subtype)
    event.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
    event.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase.rawValue))

    if type == .swipe {
        event.setDoubleValueField(CGEventField(rawValue: 116)!, value: dx)
        event.setDoubleValueField(CGEventField(rawValue: 119)!, value: dy)
    }

    event.post(tap: .cghidEventTap)
}
