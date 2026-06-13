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
            //TODO: consider moving modifier flag check to caller (NeoMouseApp)
            //As functions should ideally just do one thing
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])),
                appState.isVisual,
                let rect = appState.currentVisualRect
            else {
                //Normal copy to register
                appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                return
            }

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
                    if isScreenCaptureTCCError(error) {
                        // -3801: user denied Screen Recording. Surface an
                        // actionable toast and open the right Settings pane
                        // — otherwise the user sees nothing copy and has no
                        // hint that a permission needs flipping. Settings
                        // grants only take effect on next launch.
                        ToastManager.shared.show(
                            "Screen Recording permission required for yank — enable in System Settings, then relaunch"
                        )
                        openScreenRecordingSettings()
                    }
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
            guard let sessionId = currentSession.id else {
                return debug("registerYank - currentSession has no id; was the session persisted?")
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
                    register: activeRegister, item: pasteboardItem, sessionId: sessionId)
                RegisterMenu.shared.refresh()
            }
        }

        @MainActor
        static func registerCurrentPasteboardItem(
            currentSession: Session, activeRegister: String
        ) {
            guard let sessionId = currentSession.id else {
                return debug(
                    "registerCurrentPasteboardItem - currentSession has no id; was the session persisted?"
                )
            }
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
                    sessionId: sessionId
                )
                RegisterMenu.shared.refresh()
                debug(
                    "registerCurrentPasteboardItem - Copied pasteboard item to register '\(activeRegister)': \(Pasteboard.preview(pasteboardItem))"
                )
            }
        }

        @MainActor
        static func autoRegisterToNumeralsCurrentPasteboardItem(
            currentSession: Session
        ) {
            guard let sessionId = currentSession.id else {
                return debug(
                    "autoRegisterToNumeralsCurrentPasteboardItem - currentSession has no id; was the session persisted?"
                )
            }
            let initialChangeCount = NSPasteboard.general.changeCount
            Pasteboard.waitForChange(after: initialChangeCount) { pasteboardItem in
                guard let pasteboardItem else {
                    return debug(
                        "autoRegisterToNumeralsCurrentPasteboardItem - timed out waiting for pasteboard change for numeral registers"
                    )
                }
                var isNotFilledNumeralRegisterExists = false
                for numeral in 1...9 {
                    let isExistingNumeralRegister =
                        Register.get(
                            register: "\(numeral)", sessionId: sessionId) != nil
                    if isExistingNumeralRegister {
                        continue
                    } else {
                        Register.set(
                            register: "\(numeral)",
                            item: pasteboardItem,
                            sessionId: sessionId
                        )
                        isNotFilledNumeralRegisterExists = true
                        break
                    }
                }
                if !isNotFilledNumeralRegisterExists {
                    debug(
                        "autoRegisterToNumeralsCurrentPasteboardItem - all numeral registers already filled, skipping auto-registering to numeral registers"
                    )
                    return
                }
                RegisterMenu.shared.refresh()
                debug(
                    "autoRegisterToNumeralsCurrentPasteboardItem - Copied pasteboard item to numeral registers: \(Pasteboard.preview(pasteboardItem))"
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
            guard let sessionId = currentSession.id else {
                return debug(
                    "registerCurrentPasteboardItemToSystemRegister - currentSession has no id; was the session persisted?"
                )
            }
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
                    sessionId: sessionId
                )
                RegisterMenu.shared.refresh()
                debug(
                    "registerCurrentPasteboardItemToSystemRegister - Copied pasteboard item to register '\(systemRegister)': \(Pasteboard.preview(pasteboardItem))"
                )
            }
        }

        @MainActor
        static func writeSystemRegistesToPasteboard(currentSession: Session, systemRegister: String = "+") {
            guard let sessionId = currentSession.id else {
                return debug(
                    "writeSystemRegistesToPasteboard - currentSession has no id; was the session persisted?"
                )
            }
            guard
                let item = Register.get(register: systemRegister, sessionId: sessionId)?
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
            guard let sessionId = currentSession.id else {
                return debug(
                    "pasteFromRegister - currentSession has no id; was the session persisted?"
                )
            }
            guard
                let item = Register.get(register: activeRegister, sessionId: sessionId)?
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
                let previousStart = appState.previousVisual.startPos,
                let previousEnd = appState.previousVisual.endPos
            else {
                debug("goToPreviousVisualState: previous visual state CG points not found, ignoring")
                return
            }
            appState.isVisual = true
            appState.visual = NeomouseType.VisualState(
                startPos: previousStart, endPos: previousEnd
            )
            VisualHighlightOverlay.shared.passAppState(state: appState)
            Mouse.moveToGlobal(x: previousEnd.x, y: previousEnd.y)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
        }

        /// Snapshots the current visual selection into `previousVisual`, clears
        /// the current selection, exits visual mode, hides the overlay, and
        /// returns to normal mode.
        @MainActor
        static func exitVisualState(
            appState: NeoMouseState, visualHighlightOverlay: VisualHighlightOverlay
        ) {
            guard appState.visual.startPos != nil, let end = appState.visual.endPos else {
                return debug(
                    "Could not retrieve start or end CG points in exitVisualState",
                    "visual: \(String(describing: appState.visual))"
                )
            }
            Mouse.up(.left, at: end)
            //TODO Eventually use Session.Operations Table
            appState.savePreviousAndClearVisual()
            //IMPORTANT: must set isVisual to false!
            appState.isVisual = false
            visualHighlightOverlay.hideOverlay()
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
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
            appState.setVisualStart(currentCGPoint)
            appState.setVisualEnd(currentCGPoint)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            VisualHighlightOverlay.shared.passAppState(state: appState)
        }
        @MainActor
        static func setFrontMostAppOnCursorAsActiveIfNeeded(
            _ appState: NeoMouseState,
        ) {
            guard appState.frontAppFollowsMouse else { return }
            guard let frontmostAppUnderCursor = Mouse.frontmostAppUnder() else {
                return
                    debug("setFrontMostAppOnCursorAsActiveIfNeeded fn - no frontmostAppUnderCursor")
            }
            Mouse.setActiveApp(frontmostAppUnderCursor)
        }
    }
}
