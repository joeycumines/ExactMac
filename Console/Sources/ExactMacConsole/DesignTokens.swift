import AppKit
import SwiftUI

/// The design system, transcribed from `docs/design/tokens.json`.
///
/// THE .FIG CANNOT SUPPLY THIS. `openpencil variables` reports no variables, every node in
/// the design carries an empty `boundVariables`, and every colour, radius and spacing value
/// in it is a hardcoded literal. The JSON is the source and the .fig is the rendered proof
/// of it; the two agree on every value below, which was checked rather than assumed.
///
/// TWO FACTS THAT A TRANSCRIPTION GETS WRONG, both verified against the artifact:
///
///   `on-accent` is DARK in dark mode — #1C1C1E, not white. The primary button's label is
///   near-black on a near-black fill's opposite, and the Foundations page shows no swatch
///   for this token at all, so a design read without the JSON would hardcode white and ship
///   a 3.31:1 label.
///
///   The declared type scale is missing four roles that are in active use. The 10/600
///   eyebrow alone carries 115 nodes and EVERY security caption in the product
///   (`REASON GIVEN BY THE AGENT — NOT VERIFIED`), so it is not optional.
enum Design {
    // MARK: - Colour

    /// One semantic name, two values, which is what makes a single SwiftUI colour
    /// possible. Never a literal at a call site: the entire point of the names is that
    /// `accent` and the ink form of accent are different colours in dark mode.
    enum Ink {
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
        static let surfaceRaised = adaptive(light: 0xF5F5F7, dark: 0x2C2C2E)
        static let surfaceSunken = adaptive(light: 0xEBEBF0, dark: 0x141416)
        static let separator = adaptive(light: 0xD2D2D7, dark: 0x3A3A3C)
        static let controlBorder = adaptive(light: 0x8A8A8F, dark: 0x5C5C61)
        static let textPrimary = adaptive(light: 0x1D1D1F, dark: 0xF5F5F7)
        static let textSecondary = adaptive(light: 0x5E5E63, dark: 0xA8A8AD)
        static let textTertiary = adaptive(light: 0x68686D, dark: 0x949499)
        /// A FILL. Coloured ink is `accentText`; using this for text fails AA in dark.
        static let accent = adaptive(light: 0x0A6CFF, dark: 0x3D8BFF)
        static let accentText = adaptive(light: 0x0A5CD5, dark: 0x66A8FF)
        /// The label colour that sits ON an accent fill. Dark in dark mode.
        static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
        static let danger = adaptive(light: 0xD70015, dark: 0xFF5E52)
        static let caution = adaptive(light: 0xA04A00, dark: 0xFF9F0A)
        static let success = adaptive(light: 0x1A753F, dark: 0x30C46C)

        private static func adaptive(light: UInt32, dark: UInt32) -> Color {
            Color(light: rgb(light), dark: rgb(dark))
        }
    }

    /// Dynamic AppKit NSColor equivalents for menu bar rasterisation and native drawing.
    enum NSInk {
        static let controlBorder = adaptive(light: 0x8A8A8F, dark: 0x5C5C61)
        static let textSecondary = adaptive(light: 0x5E5E63, dark: 0xA8A8AD)
        static let caution = adaptive(light: 0xA04A00, dark: 0xFF9F0A)
        static let success = adaptive(light: 0x1A753F, dark: 0x30C46C)

        private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                    green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(hex & 0xFF) / 255.0,
                    alpha: 1.0,
                )
            }
        }
    }

    /// A literal sRGB colour. Named `rgb` rather than `Color` because a static member called
    /// `Color` shadows the type it returns, which is a confusing error to read.
    static func rgb(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1,
        )
    }

    // MARK: - Space

    /// The 4pt grid, 8 and above being the primary rhythm. Plus the de-facto values the
    /// design actually uses and does not declare: 2, 3, 5, 6, 9, 10, 13, 14 appear on 1,400+
    /// nodes, and 10 is the de-facto component padding throughout the library.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 3
        static let one: CGFloat = 4
        static let row: CGFloat = 5
        static let leading: CGFloat = 6
        static let two: CGFloat = 8
        static let chip: CGFloat = 9
        static let component: CGFloat = 10
        static let three: CGFloat = 12
        static let clearingRule: CGFloat = 13
        static let frame: CGFloat = 14
        static let four: CGFloat = 16
        static let five: CGFloat = 20
        /// The ProcessTree indent unit, exactly +20 per depth level.
        static let treeIndent: CGFloat = 20
        static let six: CGFloat = 24
        static let eight: CGFloat = 32
        static let ten: CGFloat = 40
    }

    // MARK: - Radius

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        /// The window and popover shell. Used nowhere else.
        static let large: CGFloat = 10
    }

    // MARK: - Type

    /// SF Pro for prose, Menlo for anything the machine will execute or reported.
    ///
    /// The weight ladder is exactly two steps. The design contains no Medium and no Bold —
    /// `tokens.json` claims a four-step ladder and the artifact does not have one — and the
    /// distinction that matters throughout is Regular against Semi Bold, not a gradient.
    enum Font {
        static func title(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        static func screenTitle(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        /// The 14/600 state label used on Screens for a settled outcome.
        static func stateLabel(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.textSecondary)
        }

        static func heading(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        static func sectionTitle(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        /// 13/600: the load-bearing lines — a grant's consequence, the decision BASIS, an
        /// option's title, an activity row's capability-adjacent claim.
        static func emphasized(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        static func body(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 13)).foregroundStyle(Ink.textPrimary)
        }

        static func caption(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11)).foregroundStyle(Ink.textSecondary)
        }

        static func captionPrimary(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11)).foregroundStyle(Ink.textPrimary)
        }

        /// 10/600, the eyebrow that carries EVERY security caption in the product. Not in
        /// the declared scale and used 115 times.
        static func eyebrow(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.textPrimary)
        }

        static func microNote(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 10)).foregroundStyle(Ink.textTertiary)
        }

        /// 9/400, seven nodes: "lands on the shared clipboard" and its two siblings.
        static func finePrint(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 9)).foregroundStyle(Ink.textTertiary)
        }

        static func value(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 12)).foregroundStyle(Ink.textPrimary)
        }

        static func valueSecondary(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 12)).foregroundStyle(Ink.textSecondary)
        }

        /// Machine text. Menlo, and the design's own note explains why the distinction has
        /// to survive without it: the design renders in Inter with NO monospace, so
        /// UntrustedField carries "not verified" on fill, an amber rule and a caption instead.
        /// In the real app the face carries it too.
        static func code(_ text: String, size: CGFloat = 12) -> some View {
            Text(text)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(Ink.textPrimary)
        }

        static func codeSecondary(_ text: String, size: CGFloat = 11) -> some View {
            Text(text)
                .font(.system(size: size, design: .monospaced)).foregroundStyle(Ink.textSecondary)
        }
    }

    // MARK: - Layout constants

    /// Read from the artifact, not guessed. `minWindowHeight` is 710 because the prompt
    /// MEASURES 710: header 237 + body 236 + footer 238. Two earlier numbers were wrong —
    /// 560 was a guess 150pt short, 704 was 6pt short — so these are measurements.
    enum Layout {
        static let promptWidth: CGFloat = 420
        /// 420 minus 16pt of padding either side. Every row in the prompt is this wide.
        static let promptContent: CGFloat = 388
        /// The ONE fixed height in the prompt, and the number that decides how much of the
        /// request the operator sees before scrolling.
        ///
        /// IT WAS 236, and the number's stated purpose was "makes the reason visible without
        /// scrolling" because the reason sat in the non-scrolling header above it. MEASURED on
        /// that arrangement: the payload block's visible portion was 0pt of 134pt — the fold
        /// fell at its first pixel — so what was visible without scrolling was the agent's own
        /// unverified prose and none of the verified request. The reason now lives IN this
        /// region, subordinate and still marked, and what must be visible without scrolling is
        /// the system's own summary, which the hugging header above carries in full.
        ///
        /// 348 IS MEASURED, and the first attempt at it was not. 320 came from arithmetic and
        /// the render showed a control bisected again — the Copy row ends at 335.5 — which is
        /// the exact defect D1 was opened to fix, reintroduced by my own arithmetic in the
        /// same file an hour later. The boundaries, measured: caption 283..297.5, Copy
        /// 305.5..335.5, the payload body's first line 343.5..360.9. The payload block
        /// separates its caption, its Copy row and its body by 8pt, so the window in which
        /// the cut bisects NOTHING is 8pt wide. 348 sits 12.5pt clear of the Copy row and
        /// slices the body's first line, which is what the cut is for: the operator has to be
        /// able to see that the request text continues rather than ends. The card is
        /// 169 + 348 + 238 = 755pt.
        static let promptScrollHeight: CGFloat = 348
        static let popoverWidth: CGFloat = 360
        static let popoverContent: CGFloat = 332
        static let windowWidth: CGFloat = 720
        static let windowContent: CGFloat = 688
        static let minWindowHeight: CGFloat = 710
    }

    // MARK: - Grammar

    /// The universal metadata delimiter: two spaces, U+00B7, two spaces. Used in every
    /// scope line, every capability line and the ProcessTree role labels. The design is
    /// inconsistent about it in two places; the double form is the dominant and deliberate
    /// one, so it is the one that ships.
    static func joined(_ parts: [String]) -> String {
        parts.joined(separator: "  ·  ")
    }

    /// The 3pt vertical rule, coloured by PROVENANCE. These are different facts and blurring
    /// them is the bug the design exists to prevent.
    enum Rule {
        /// Someone else wrote this. The agent's reason, and nothing else.
        static let untrusted = Ink.caution
        /// We cannot tell you this. Every system error and every fail-closed band.
        static let unknown = Ink.controlBorder
    }
}

private extension Color {
    /// Two values under one name, which is what makes a semantic colour possible at all.
    ///
    /// Built on a dynamic `NSColor` so it tracks the SYSTEM appearance, not the SwiftUI
    /// scheme: the console is a menu-bar accessory and follows the user's Mac setting, and
    /// a console that inverted independently of the rest of the system would be a second
    /// appearance rather than one design.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
