@testable import ExactMacConsole
import Foundation
import Testing

/// Mechanical WCAG AA contrast verification computed directly from tokens.json.
///
/// Every text token must clear 4.5:1 against surface, surface-raised, and surface-sunken
/// in BOTH light and dark schemes. Additionally, on-accent must clear 4.5:1 on accent.
@Suite("Design token contrast verification")
struct DesignTokenContrastTests {
    struct ColorSchemeTokens: Decodable {
        let light: String
        let dark: String

        subscript(scheme: Scheme) -> String {
            switch scheme {
            case .light: light
            case .dark: dark
            }
        }
    }

    enum Scheme: String, CaseIterable {
        case light
        case dark
    }

    struct TokensJSON: Decodable {
        let color: [String: ColorSchemeTokens]

        enum CodingKeys: String, CodingKey {
            case color
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let colorDict = try container.decode([String: ColorSchemeTokensOrComment].self, forKey: .color)
            var parsedColors: [String: ColorSchemeTokens] = [:]
            for (key, val) in colorDict {
                if let tokens = val.tokens {
                    parsedColors[key] = tokens
                }
            }
            self.color = parsedColors
        }
    }

    enum ColorSchemeTokensOrComment: Decodable {
        case tokens(ColorSchemeTokens)
        case comment

        var tokens: ColorSchemeTokens? {
            switch self {
            case let .tokens(t): t
            case .comment: nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let t = try? container.decode(ColorSchemeTokens.self) {
                self = .tokens(t)
            } else {
                self = .comment
            }
        }
    }

    private static func loadTokensJSON() throws -> (authoritative: TokensJSON, bundled: TokensJSON) {
        // Resolve paths from bundle or file system
        let bundleURL = Bundle.module.url(forResource: "tokens", withExtension: "json")
        let bundledData: Data
        if let bundleURL, let data = try? Data(contentsOf: bundleURL) {
            bundledData = data
        } else {
            let fallbackURL = URL(fileURLWithPath: "Sources/ExactMacConsole/Resources/tokens.json")
            bundledData = try Data(contentsOf: fallbackURL)
        }

        // Authoritative file at docs/design/tokens.json
        let possibleAuthoritativePaths = [
            URL(fileURLWithPath: "docs/design/tokens.json"),
            URL(fileURLWithPath: "../../docs/design/tokens.json"),
            URL(fileURLWithPath: "../docs/design/tokens.json"),
        ]
        var authoritativeData: Data?
        for path in possibleAuthoritativePaths {
            if let data = try? Data(contentsOf: path) {
                authoritativeData = data
                break
            }
        }
        guard let authData = authoritativeData else {
            // If running isolated without repo checkout, compare bundled against itself
            let bundled = try JSONDecoder().decode(TokensJSON.self, from: bundledData)
            return (bundled, bundled)
        }

        let decoder = JSONDecoder()
        let auth = try decoder.decode(TokensJSON.self, from: authData)
        let bundled = try decoder.decode(TokensJSON.self, from: bundledData)
        return (auth, bundled)
    }

    // MARK: - WCAG 2.1 Mathematics

    /// Relative luminance per WCAG 2.1 definition:
    /// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    private static func relativeLuminance(hex: String) -> Double {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6, let intVal = UInt64(cleanHex, radix: 16) else {
            return 0.0
        }
        let r = Double((intVal >> 16) & 0xFF) / 255.0
        let g = Double((intVal >> 8) & 0xFF) / 255.0
        let b = Double(intVal & 0xFF) / 255.0

        func adjustChannel(_ c: Double) -> Double {
            if c <= 0.04045 {
                c / 12.92
            } else {
                pow((c + 0.055) / 1.055, 2.4)
            }
        }

        let rLum = adjustChannel(r)
        let gLum = adjustChannel(g)
        let bLum = adjustChannel(b)

        return 0.2126 * rLum + 0.7152 * gLum + 0.0722 * bLum
    }

    /// Contrast ratio between two sRGB hex colours:
    /// (L1 + 0.05) / (L2 + 0.05) where L1 is the lighter colour.
    private static func contrastRatio(hex1: String, hex2: String) -> Double {
        let l1 = relativeLuminance(hex: hex1)
        let l2 = relativeLuminance(hex: hex2)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - Tests

    @Test
    func `bundled tokens match authoritative docs design tokens`() throws {
        let (auth, bundled) = try Self.loadTokensJSON()
        for (key, authTokens) in auth.color {
            guard let bundledTokens = bundled.color[key] else {
                Issue.record("Bundled tokens missing key \(key)")
                continue
            }
            #expect(bundledTokens.light == authTokens.light, "Light mismatch for \(key)")
            #expect(bundledTokens.dark == authTokens.dark, "Dark mismatch for \(key)")
        }
    }

    @Test
    func `every text token meets WCAG AA 4_5 to 1 on all three surfaces in light and dark`() throws {
        let (tokens, _) = try Self.loadTokensJSON()

        let textTokenNames = [
            "text-primary",
            "text-secondary",
            "text-tertiary",
            "accent-text",
            "danger",
            "caution",
            "success",
        ]

        let surfaceTokenNames = [
            "surface",
            "surface-raised",
            "surface-sunken",
        ]

        for scheme in Scheme.allCases {
            for textName in textTokenNames {
                guard let textColor = tokens.color[textName]?[scheme] else {
                    Issue.record("Missing text token \(textName) for scheme \(scheme.rawValue)")
                    continue
                }
                for surfaceName in surfaceTokenNames {
                    guard let surfaceColor = tokens.color[surfaceName]?[scheme] else {
                        Issue.record("Missing surface token \(surfaceName) for scheme \(scheme.rawValue)")
                        continue
                    }
                    let ratio = Self.contrastRatio(hex1: textColor, hex2: surfaceColor)
                    #expect(
                        ratio >= 4.5,
                        "WCAG AA failure: \(textName) (\(textColor)) on \(surfaceName) (\(surfaceColor)) in \(scheme.rawValue) mode has contrast \(String(format: "%.2f", ratio)):1 < 4.5:1",
                    )
                }
            }
        }
    }

    @Test
    func `on-accent meets WCAG AA 4_5 to 1 on accent fill in light and dark`() throws {
        let (tokens, _) = try Self.loadTokensJSON()

        for scheme in Scheme.allCases {
            guard let accentFill = tokens.color["accent"]?[scheme],
                  let onAccentInk = tokens.color["on-accent"]?[scheme]
            else {
                Issue.record("Missing accent or on-accent for scheme \(scheme.rawValue)")
                continue
            }
            let ratio = Self.contrastRatio(hex1: onAccentInk, hex2: accentFill)
            #expect(
                ratio >= 4.5,
                "WCAG AA failure: on-accent (\(onAccentInk)) on accent (\(accentFill)) in \(scheme.rawValue) mode has contrast \(String(format: "%.2f", ratio)):1 < 4.5:1",
            )
        }
    }
}
