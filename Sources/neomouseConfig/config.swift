import CoreGraphics
import Foundation
import TOMLDecoder

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

    public struct Grid: Decodable, Sendable {
        public let inset: CGFloat
        public let divisions: Int
        public let innerDivisions: Int
        // Single string for ergonomics in TOML; callers that need `[String]`
        // should `.map { String($0) }`.
        public let findModeCharacters: String
        public let findModeInnerCharacters: String
        public let isAlwaysShowInnerCharacters: Bool
    }

    public struct Motion: Decodable, Sendable {
        public let linesOnScreen: CGFloat
        public let rangeX: CGFloat
        public let rangeY: CGFloat
        public let isClampCursorToCurrentScreen: Bool
    }

    public struct Visual: Decodable, Sendable {
        public let minimumHighlightWidth: Int
    }

    public struct Gesture: Decodable, Sendable {
        public let zoomStepValue: Double
        public let incrementsPerGesture: UInt
        public let degreesToRotate: Double
    }

    public struct Commands: Decodable, Sendable {
        public let available: [String]
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
