import CoreGraphics
import Foundation
import TOMLDecoder

import neomouseTypes

// Configurable settings sourced from `settings.toml`. Mirrors the constant
// (`let`) properties of `NeoMouseState`, plus `gridInset` which is declared
// `@Published` but never reassigned. Runtime/observable state (mode, visual
// selection coordinates, etc.) stays on `NeoMouseState`.
//
// TOML keys are snake_case; properties are camelCase via TOMLDecoder's
// `.convertFromSnakeCase` strategy.
public struct Config: Decodable, Sendable {
    public let grid: Grid
    public let motion: Motion
    public let visual: Visual
    public let gesture: Gesture
    public let commands: Commands
    public let configuration: Configuration

    public struct Grid: Decodable, Sendable {
        public let inset: CGFloat
        public let divisions: Int
        public let innerDivisions: Int
        // Single string for ergonomics in TOML; callers that need `[String]`
        // should `.map { String($0) }`.
        public let findModeCharacters: String
        public let findModeInnerCharacters: String
        public let isAlwaysShowInnerCharacters: Bool

        // Fallback values when settings.toml is absent / missing the section.
        // Update here; the NeoMouseState init no longer carries its own copy.
        public static let defaultInset: CGFloat = 10
        public static let defaultDivisions: Int = 5
        public static let defaultInnerDivisions: Int = 3
        public static let defaultFindModeCharacters = "abcdefghijklmnopqrstuvwxyz"
        public static let defaultFindModeInnerCharacters = "abcdefghijklmnopqrstuvwxyz"
        public static let defaultIsAlwaysShowInnerCharacters = true
    }

    public struct Motion: Decodable, Sendable {
        public let linesOnScreen: Int
        public let rangeX: CGFloat
        public let rangeY: CGFloat
        public let isClampCursorToCurrentScreen: Bool

        public static let defaultLinesOnScreen: Int = 50
        public static let defaultRangeX: CGFloat = 20
        public static let defaultRangeY: CGFloat = 20
        public static let defaultIsClampCursorToCurrentScreen = false
    }

    public struct Visual: Decodable, Sendable {
        public let minimumHighlightWidth: Int

        public static let defaultMinimumHighlightWidth: Int = 5
    }

    public struct Gesture: Decodable, Sendable {
        public let zoomStepValue: Double
        public let incrementsPerGesture: UInt
        public let degreesToRotate: Double

        public static let defaultZoomStepValue: Double = 0.1
        public static let defaultIncrementsPerGesture: UInt = 5
        public static let defaultDegreesToRotate: Double = 90
    }

    public struct Commands: Decodable, Sendable {
        public let available: [Command]
        /// Single source of truth for the fallback list when settings.toml is
        /// missing or has no `[commands]` section. Update here; nowhere else.
        public static let defaultAvailable: [Command] = [
            .numbers, .nu, .relativenumbers, .rnu, .help, .h, .delmarks, .delm, .registers, .reg,
        ]
    }

    public enum Command: String, Decodable, Sendable {
        case numbers, nu
        case relativenumbers, rnu
        case registers, reg
        case jumps, ju
        case help, h
        case delmarks, delm
        case q, quit
    }

    public struct Configuration: Decodable, Sendable {
        public let isDisableKeyInput: Bool
        public let maxSessionCount: UInt
        public let newSessionOnOpen: Bool
        public let modeOnStart: NeomouseType.ConfigMode

        public static let defaultIsDisableKeyInput: Bool = true
        public static let defaultMaxSessionCount: UInt = 10
        public static let defaultNewSessionOnOpen: Bool = false
        public static let defaultModeOnStart: NeomouseType.ConfigMode = .normal
    }
}

extension Config {

    public enum LoadError: Error, CustomStringConvertible {
        case fileNotFound(URL)
        case readFailed(URL, underlying: Error)
        case decodeFailed(URL, underlying: Error)

        public var description: String {
            switch self {
            case .fileNotFound(let url):
                return "Config not found at \(url.path)"
            case .readFailed(let url, let underlying):
                return "Failed to read config at \(url.path): \(underlying)"
            case .decodeFailed(let url, let underlying):
                return "Failed to decode TOML at \(url.path): \(underlying)"
            }
        }
    }

    // Resolution order:
    //   1. $NEOMOUSE_CONFIG (explicit override)
    //   2. ~/.config/neomouse/settings.toml
    //   3. ~/Library/Application Support/neomouse/settings.toml
    public static var resolvedURL: URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NEOMOUSE_CONFIG"],
            !override.isEmpty
        {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let candidates: [URL] = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/neomouse/settings.toml"),
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("neomouse/settings.toml"),
        ].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    public static func loadConfig(from url: URL) throws(LoadError) -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .fileNotFound(url)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .readFailed(url, underlying: error)
        }
        let decoder = TOMLDecoder(strategy: .init(key: .convertFromSnakeCase))
        do {
            return try decoder.decode(Config.self, from: text)
        } catch {
            throw .decodeFailed(url, underlying: error)
        }
    }
}
