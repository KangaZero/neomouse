import AppKit
import CoreGraphics

import neomouseUtils
import neomouseTypes
import neomouseDB

// @MainActor
extension NeoMouse {
    //TODO decide whether to move to neomouseUtils instead
    public enum CoreOperations {
        @MainActor
        public static let excludedWindowIDsForScreenshot: [CGWindowID] = [
            VisualHighlightOverlay.shared.windowID,
            GridOverlay.shared.windowID,
            ToastManager.shared.windowID,
            HelpDialog.shared.windowID,
            CommandLine.shared.windowID,
            NumbersOverlay.shared.windowID,
        ].compactMap { $0 }

        @MainActor
        static func normalYank(event: NSEvent, currentSession: Session, appState: NeoMouseState) {
            appState.operationCountAsString = nil
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])),
                appState.isVisual,
                let startX = appState.startCGXPoint,
                let startY = appState.startCGYPoint,
                let endX = appState.endCGXPoint,
                let endY = appState.endCGYPoint
            else {
                //Normal copy to register
                appState.mode = .normal(currentPendingOperation: .none)
                return
            }
            let currentVisualHighlightWidth: CGFloat = abs(endX - startX)
            let currentVisualHighlightHeight: CGFloat = abs(endY - startY)
            let currentVisualHighlightCGRect = CGRect(
                x: min(startX, endX),
                y: min(startY, endY),
                width: currentVisualHighlightWidth,
                height: currentVisualHighlightHeight
            )
            let rect = currentVisualHighlightCGRect

            Task { @MainActor in
                do {
                    guard
                        let screenshotTaken = try await screenshotMultiDisplay(
                            rect: rect, excluding: Self.excludedWindowIDsForScreenshot)
                    else {
                        debug("No screenshotTaken for operation: y")
                        appState.mode = .normal(currentPendingOperation: .none)
                        appState.isVisual = false
                        return
                    }
                    let image = NSImage(cgImage: screenshotTaken, size: .zero)
                    NSSound(named: "Screen Capture")?.play()
                    NSPasteboard.general.clearContents()
                    let isCopiedToPasteBoard = NSPasteboard.general.writeObjects([image])
                    if isCopiedToPasteBoard {
                        ToastManager.shared.show("Screenshot copied to clipboard")
                    }

                    appState.mode = .normal(currentPendingOperation: .none)
                    appState.isVisual = false
                } catch {
                    debug("For operation 'y' screenshot failed: \(error)")
                    appState.mode = .normal(currentPendingOperation: .none)
                    appState.isVisual = false
                }
            }
        }

        @MainActor
        static func registerYank(event: NSEvent, currentSession: Session, activeRegister: String) {
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ]))
            else {
                return
            }
            System.simulate(.copy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let pasteboardItem = NSPasteboard.general.pasteboardItems?.first {
                    debug("Copied item to clipboard: \(Pasteboard.preview(pasteboardItem))")
                    Register.set(
                        register: activeRegister, item: pasteboardItem, sessionId: currentSession.id!)
                }
            }

        }

        @MainActor
        static func registerCurrentPasteboardItem(
            currentSession: Session, activeRegister: String
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let pasteboardItem = NSPasteboard.general.pasteboardItems?.first {
                    Register.set(
                        register: activeRegister,
                        item: pasteboardItem,
                        sessionId: currentSession.id!
                    )
                    debug(
                        "registerCurrentPasteboardItem - Copied pasteboard item to register '\(activeRegister)': \(Pasteboard.preview(pasteboardItem))"
                    )
                } else {
                    debug(
                        "registerCurrentPasteboardItem - No pasteboard item found to copy to register '\(activeRegister)'"
                    )
                }
            }

        }

        @MainActor
        static func delete(event: NSEvent, appState: NeoMouseState, currentSession: Session) {
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ]))
            else {
                return
            }
            System.simulate(.cut)
        }

        @MainActor
        static func pasteFromRegister(
            event: NSEvent, appState: NeoMouseState, currentSession: Session, activeRegister: String
        ) {
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ]))
            else {
                return
            }
            guard
                let item = Register.get(register: activeRegister, sessionId: currentSession.id!)?
                    .pasteboardItem
            else {
                debug("pasteFromRegister: register '\(activeRegister)' empty")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                System.simulate(.paste)
            }
        }

        @MainActor
        static func toggleVisualState(
            event: NSEvent, appState: NeoMouseState,
            currentPendingNormalOperation: NeomouseType.NormalModePendingOperation,
            currentCGPoint: CGPoint
        ) {
            appState.operationCountAsString = nil
            guard event.modifierFlags.rawValue == 256 else {
                debug("toggleVisualState: \(event.modifierFlags.rawValue) doesn't match 256, ignoring")
                return appState.mode = .normal(currentPendingOperation: .none)
            }
            appState.isVisual.toggle()
            guard appState.isVisual else {
                exitVisualMode(
                    appState: appState,
                    visualHighlightOverlay:
                        VisualHighlightOverlay.shared)
                return
            }
            if currentPendingNormalOperation == .g
                && appState.previousVisualStartCGXPoint != nil
                && appState.previousVisualStartCGYPoint != nil
                && appState.previousVisualEndCGXPoint != nil
                && appState.previousVisualEndCGYPoint != nil
            {
                // Mouse.down(.left, at: currentCGPoint)
                appState.startCGXPoint = appState.previousVisualStartCGXPoint
                appState.startCGYPoint = appState.previousVisualStartCGYPoint
                appState.endCGXPoint = appState.previousVisualEndCGXPoint
                appState.endCGYPoint = appState.previousVisualEndCGYPoint
                VisualHighlightOverlay.shared.passAppState(state: appState)
                Mouse.moveToGlobal(
                    x: appState.endCGXPoint!,
                    y: appState.endCGYPoint!)
                appState.mode = .normal(currentPendingOperation: .none)
            } else {
                //Go to Visual state
                // Mouse.down(.left, at: currentCGPoint)
                appState.startCGXPoint = currentCGPoint.x
                appState.startCGYPoint = currentCGPoint.y
                appState.endCGXPoint = currentCGPoint.x
                appState.endCGYPoint = currentCGPoint.y
                VisualHighlightOverlay.shared.passAppState(state: appState)
                appState.mode = .normal(currentPendingOperation: .none)
            }
        }

    }
}
