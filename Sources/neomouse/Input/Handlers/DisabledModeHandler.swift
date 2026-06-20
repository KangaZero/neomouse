import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Cmd-E / global re-enable path runs *above* the mode switch in the
    /// main closure, so a disabled-mode keystroke really has nothing to do.
    @MainActor
    static func handleDisabledMode(ctx: KeyEventContext) {
        // intentionally empty — caller returns immediately after.
    }
}
