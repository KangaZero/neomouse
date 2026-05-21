import AppKit

import neomouseUtils
import neomouseDB

extension NeoMouse {
    //TODO decide whether to move to neomouseUtils instead
    public enum CoreOperations {
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
            //TODO move this somewhere common to be reusable
            let excludedIDs: [CGWindowID] = [
                VisualHighlightOverlay.shared.windowID,
                GridOverlay.shared.windowID,
                ToastManager.shared.windowID,
                HelpDialog.shared.windowID,
                CommandLine.shared.windowID,
                NumbersOverlay.shared.windowID,
            ].compactMap { $0 }
            Task { @MainActor in
                do {
                    guard
                        let screenshotTaken = try await screenshotMultiDisplay(
                            rect: rect, excluding: excludedIDs)
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
        static func registerScreenshot(
            event: NSEvent, appState: NeoMouseState, currentSession: Session, activeRegister: String
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let pasteboardItem = NSPasteboard.general.pasteboardItems?.first {
                    Register.set(
                        register: activeRegister,
                        item: pasteboardItem,
                        sessionId: currentSession.id!
                    )
                    debug(
                        "Copied screenshot item to register '\(activeRegister)': \(Pasteboard.preview(pasteboardItem))"
                    )
                } else {
                    debug(
                        "mode: \(appState.mode) is not .normal(.registerAction) or no pasteboard item found after screenshot for operation 'y'"
                    )
                }
            }

        }
    }
}
