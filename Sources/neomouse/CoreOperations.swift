import AppKit
import CoreGraphics

import neomouseUtils
import neomouseTypes
import neomouseDB

extension NeoMouse {
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
            // appState.operationCountAsString = nil
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
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
                appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
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
                        appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
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

                    appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                    appState.isVisual = false
                } catch {
                    debug("For operation 'y' screenshot failed: \(error)")
                    appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                    appState.isVisual = false
                }
            }
        }

        @MainActor
        static func registerYank(event: NSEvent, currentSession: Session, activeRegister: String) {
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ]))
            else {
                return
            }
            // Capture BEFORE we trigger ⌘C so the polling helper has a stable
            // reference point. Reading changeCount after simulate(.copy) would
            // race against the synthesized event itself.
            let initialChangeCount = NSPasteboard.general.changeCount
            System.simulate(.copy)
            Pasteboard.waitForChange(after: initialChangeCount) { pasteboardItem in
                guard let pasteboardItem else {
                    return debug(
                        "registerYank - timed out waiting for ⌘C to land on register '\(activeRegister)'")
                }
                debug("Copied item to clipboard: \(Pasteboard.preview(pasteboardItem))")
                Register.set(
                    register: activeRegister, item: pasteboardItem, sessionId: currentSession.id!)
                RegisterMenu.shared.refresh()
            }
        }

        @MainActor
        static func registerCurrentPasteboardItem(
            currentSession: Session, activeRegister: String
        ) {
            // Capture immediately on entry. Typical caller pattern is
            // normalYank() then registerCurrentPasteboardItem() — at this
            // point normalYank's screenshot Task hasn't yet written to the
            // pasteboard, so the captured count is genuinely "pre-write."
            // waitForChange then blocks until the Task lands its writeObjects,
            // which avoids the race where a fixed 100ms delay would fire
            // before the screenshot pipeline finished.
            let initialChangeCount = NSPasteboard.general.changeCount
            Pasteboard.waitForChange(after: initialChangeCount) { pasteboardItem in
                guard let pasteboardItem else {
                    return debug(
                        "registerCurrentPasteboardItem - timed out waiting for pasteboard change for register '\(activeRegister)'"
                    )
                }
                Register.set(
                    register: activeRegister,
                    item: pasteboardItem,
                    sessionId: currentSession.id!
                )
                RegisterMenu.shared.refresh()
                debug(
                    "registerCurrentPasteboardItem - Copied pasteboard item to register '\(activeRegister)': \(Pasteboard.preview(pasteboardItem))"
                )
            }
        }

        @MainActor
        static func delete(event: NSEvent, appState: NeoMouseState, currentSession: Session) {
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
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

        //MARK: Register related operations

        @MainActor
        static func registerCurrentPasteboardItemToSystemRegister(
            currentSession: Session, systemRegister: String = "+"
        ) {
            let initialChangeCount = NSPasteboard.general.changeCount
            Pasteboard.waitForChange(after: initialChangeCount) { pasteboardItem in
                guard let pasteboardItem else {
                    return debug(
                        "registerCurrentPasteboardItemToSystemRegister - timed out for register '\(systemRegister)'"
                    )
                }
                Register.set(
                    register: systemRegister,
                    item: pasteboardItem,
                    sessionId: currentSession.id!
                )
                RegisterMenu.shared.refresh()
                debug(
                    "registerCurrentPasteboardItemToSystemRegister - Copied pasteboard item to register '\(systemRegister)': \(Pasteboard.preview(pasteboardItem))"
                )
            }
        }

        @MainActor
        static func writeSystemRegistesToPasteboard(currentSession: Session, systemRegister: String = "+") {
            guard
                let item = Register.get(register: systemRegister, sessionId: currentSession.id!)?
                    .pasteboardItem
            else {
                debug("writeSystemRegistesToPasteboard: register '\(systemRegister)' empty")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }

        @MainActor
        static func pasteFromRegister(
            event: NSEvent, appState: NeoMouseState, currentSession: Session, activeRegister: String
        ) {
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
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
            DispatchQueue.main.async {
                System.simulate(.paste)
            }
        }

        @MainActor
        static func goToPreviousVisualState(
            event: NSEvent, appState: NeoMouseState,
            currentPendingNormalOperation: NeomouseType.NormalModePendingOperation
        ) {
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
            guard event.modifierFlags.rawValue == 256 else {
                debug("goToPreviousVisualState: \(event.modifierFlags.rawValue) doesn't match 256, ignoring")
                return
            }
            guard !appState.isVisual else {
                debug("goToPreviousVisualState: already in visual state, ignoring")
                return
            }
            guard
                appState.previousVisualStartCGXPoint != nil && appState.previousVisualStartCGYPoint != nil
                    && appState.previousVisualEndCGXPoint != nil && appState.previousVisualEndCGYPoint != nil
            else {
                debug("goToPreviousVisualState: previous visual state CG points not found, ignoring")
                return
            }
            appState.isVisual = true
            appState.startCGXPoint = appState.previousVisualStartCGXPoint
            appState.startCGYPoint = appState.previousVisualStartCGYPoint
            appState.endCGXPoint = appState.previousVisualEndCGXPoint
            appState.endCGYPoint = appState.previousVisualEndCGYPoint
            VisualHighlightOverlay.shared.passAppState(state: appState)
            Mouse.moveToGlobal(
                x: appState.endCGXPoint!,
                y: appState.endCGYPoint!)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            // appState.operationCountAsString = nil
        }

        /// Sets previousVisualCGPoints with the current CG points,
        /// clears current CG points,
        /// sets NeomouseState isVisual to false
        /// hides visual overlay
        /// lastly sets mode to normal with no pending operation and clears operationCountAsString
        @MainActor
        static func exitVisualState(
            appState: NeoMouseState, visualHighlightOverlay: VisualHighlightOverlay
        ) {
            guard appState.startCGXPoint != nil && appState.endCGXPoint != nil else { return }
            Mouse.up(.left, at: CGPoint(x: appState.endCGXPoint!, y: appState.endCGYPoint!))
            //TODO Eventually use Session.Operations Table
            guard
                appState.startCGXPoint != nil && appState.startCGYPoint != nil
                    && appState.endCGXPoint != nil && appState.endCGYPoint != nil
            else {
                return debug(
                    "Could not retrieve start or end CG points in exitVisualState",
                    "startCGPoint:\(String(describing: appState.startCGXPoint)), \(String(describing: appState.startCGYPoint)), endCGPoint: \(String(describing: appState.endCGXPoint)), \(String(describing: appState.endCGYPoint))"
                )
            }
            appState.previousVisualStartCGXPoint = appState.startCGXPoint
            appState.previousVisualStartCGYPoint = appState.startCGYPoint
            appState.previousVisualEndCGXPoint = appState.endCGXPoint
            appState.previousVisualEndCGYPoint = appState.endCGYPoint
            appState.startCGXPoint = nil
            appState.startCGYPoint = nil
            appState.endCGXPoint = nil
            appState.endCGYPoint = nil
            //IMPORTANT: must set isVisual to false!
            appState.isVisual = false
            visualHighlightOverlay.hideOverlay()
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            // appState.operationCountAsString = nil
        }

        @MainActor
        static func toggleVisualState(
            event: NSEvent, appState: NeoMouseState,
            currentPendingNormalOperation: NeomouseType.NormalModePendingOperation,
            currentCGPoint: CGPoint,
            visualHighlightOverlay: VisualHighlightOverlay
        ) {
            // appState.operationCountAsString = nil
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
            guard event.modifierFlags.rawValue == 256 else {
                debug("toggleVisualState: \(event.modifierFlags.rawValue) doesn't match 256, ignoring")
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                // return appState.operationCountAsString = nil
            }
            appState.isVisual.toggle()
            guard appState.isVisual else {
                exitVisualState(
                    appState: appState,
                    visualHighlightOverlay:
                        VisualHighlightOverlay.shared)
                return
            }
            //Enter visual state
            appState.startCGXPoint = currentCGPoint.x
            appState.startCGYPoint = currentCGPoint.y
            appState.endCGXPoint = currentCGPoint.x
            appState.endCGYPoint = currentCGPoint.y
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            VisualHighlightOverlay.shared.passAppState(state: appState)
        }
    }
}
