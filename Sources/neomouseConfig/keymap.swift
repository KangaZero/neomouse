// import AppKit
//
// enum KeymapComponents {
//     case shift
//     case control
//     case ctrl
//     case option
//     case alt
//     case command
//     case cmd
//     case characters(String)  //Same as NSEvent.characters
//     case FunctionKeycodeCharacter(FunctionKeycodeCharacter)
// }
//
// enum FunctionKeycodeCharacter {
//     case Esc
//     case Space
//     case Tab
//     case Enter
//     case Delete
//     case UpArrow
//     case DownArrow
//     case LeftArrow
//     case RightArrow
// }
//
// struct KeyInfo {
//     let keyCode: CGKeyCode
//     let characters: String
// }
//
// let keymapKeycodeCharacterMap: [FunctionKeycodeCharacter: KeyInfo] = [
//     .Esc: KeyInfo(keyCode: 53, characters: "\u{1B}"),
//     .Space: KeyInfo(keyCode: 49, characters: " "),
//     .Tab: KeyInfo(keyCode: 48, characters: "\t"),
//     .Enter: KeyInfo(keyCode: 36, characters: "\r"),
//     .Delete: KeyInfo(keyCode: 51, characters: "\u{7F}"),
//     .UpArrow: KeyInfo(keyCode: 126, characters: ""),
//     .DownArrow: KeyInfo(keyCode: 125, characters: ""),
//     .LeftArrow: KeyInfo(keyCode: 123, characters: ""),
//     .RightArrow: KeyInfo(keyCode: 124, characters: ""),
// ]
//
// public struct NeomouseKeyEvent {
//     var keymap: String
//     var modifierFlags: NSEvent.ModifierFlags
//     var pendingCharacter: Character?
//     var character: Character
//     var functionKeyCode: UInt16?
// }
//
// public func keymapToNeomouseKeyEvent(keymap: String) -> NeomouseKeyEvent {
//     let keymapComponents: [String] = keymap.split(separator: "+")
//             var modifierFlags: NSEvent.ModifierFlags = []
//
//     for component in keymapComponents {
//         switch component {
//         case .shift:
//             modifierFlags.insert(.shift)
//         break
//         case .ctrl, .control:
//             modifierFlags.insert(.control)
//         break
//         case .option, .alt:
//             modifierFlags.insert(.option)
//         break
//         case .command, .cmd:
//             modifierFlags.insert(.command)
//         break
//         case .FunctionKeycodeCharacter(let functionKey):
//         if let keyInfo = keymapKeycodeCharacterMap[functionKey] {
//         keyCode = keyInfo.keyCode
//         }
//         break
//         default:
//                 continue
//             }
//         }
//     }
//
