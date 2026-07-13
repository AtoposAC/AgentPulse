import SwiftUI
import AgentPulseCore

public enum AgentPulseColors {
    public static let thinking = Color(hex: 0xD6A34A)
    public static let working = Color(hex: 0x46BE86)
    public static let attention = Color(hex: 0xF87171)
    public static let token = Color(hex: 0x9589DD)
    public static let idle = Color(hex: 0x6B7280)
    public static let capsuleBackground = Color(red: 246 / 255, green: 248 / 255, blue: 252 / 255).opacity(0.78)
    public static let capsuleText = Color(red: 26 / 255, green: 31 / 255, blue: 44 / 255)
    public static let divider = Color.black.opacity(0.08)
}

public extension AgentPulseSettings {
    func isDarkMode(system colorScheme: ColorScheme) -> Bool {
        switch theme {
        case .system: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func primaryText(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme) ? Color.white.opacity(0.92) : Color(red: 26 / 255, green: 31 / 255, blue: 44 / 255)
    }

    func secondaryText(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme) ? Color.white.opacity(0.70) : primaryText(system: colorScheme).opacity(0.58)
    }

    func tertiaryText(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme) ? Color.white.opacity(0.45) : primaryText(system: colorScheme).opacity(0.46)
    }

    func errorText(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme) ? Color.white.opacity(0.65) : AgentPulseColors.attention
    }

    func dividerColor(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme) ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    func capsuleFill(system colorScheme: ColorScheme) -> Color {
        isDarkMode(system: colorScheme)
            ? Color(red: 18 / 255, green: 23 / 255, blue: 34 / 255).opacity(0.88)
            : Color.white.opacity(0.86)
    }

    func capsuleHighlight(system colorScheme: ColorScheme) -> [Color] {
        isDarkMode(system: colorScheme)
            ? [Color.white.opacity(0.10), Color.white.opacity(0.03)]
            : [Color.white.opacity(0.58), Color.white.opacity(0.20)]
    }

    func capsuleStroke(system colorScheme: ColorScheme) -> [Color] {
        isDarkMode(system: colorScheme)
            ? [Color.white.opacity(0.20), Color.white.opacity(0.06)]
            : [Color.white.opacity(0.86), Color.white.opacity(0.32)]
    }

    func panelFill(system colorScheme: ColorScheme) -> Color {
        if isDarkMode(system: colorScheme) {
            guard glassEnabled else {
                return Color(red: 24 / 255, green: 29 / 255, blue: 40 / 255)
            }
            return Color(red: 18 / 255, green: 20 / 255, blue: 26 / 255)
                .opacity(glassIntensity == .enhanced ? 0.68 : 0.60)
        }
        guard glassEnabled else {
            return Color(red: 246 / 255, green: 248 / 255, blue: 252 / 255)
        }
        return Color(red: 248 / 255, green: 250 / 255, blue: 255 / 255)
            .opacity(glassIntensity == .enhanced ? 0.18 : 0.26)
    }

    func panelStrokeOpacity(system colorScheme: ColorScheme) -> Double {
        if isDarkMode(system: colorScheme) {
            return glassEnabled ? (glassIntensity == .enhanced ? 0.38 : 0.28) : 0.14
        }
        guard glassEnabled else { return 0.34 }
        return glassIntensity == .enhanced ? 0.92 : 0.72
    }

    func panelShadowOpacity(system colorScheme: ColorScheme) -> Double {
        if isDarkMode(system: colorScheme) {
            return glassEnabled ? (glassIntensity == .enhanced ? 0.34 : 0.26) : 0.22
        }
        guard glassEnabled else { return 0.10 }
        return glassIntensity == .enhanced ? 0.16 : 0.11
    }

    func settingsBackdrop(system colorScheme: ColorScheme) -> LinearGradient {
        if isDarkMode(system: colorScheme) {
            return LinearGradient(
                colors: [
                    Color(red: 9 / 255, green: 12 / 255, blue: 18 / 255).opacity(glassEnabled ? 0.78 : 1),
                    Color(red: 25 / 255, green: 29 / 255, blue: 40 / 255).opacity(glassEnabled ? 0.52 : 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return settingsBackdrop
    }

    var panelFill: Color {
        guard glassEnabled else { return Color.white }
        return Color(red: 248 / 255, green: 250 / 255, blue: 255 / 255)
            .opacity(glassIntensity == .enhanced ? 0.18 : 0.26)
    }

    var panelStrokeOpacity: Double {
        guard glassEnabled else { return 0.34 }
        return glassIntensity == .enhanced ? 0.82 : 0.62
    }

    var panelShadowOpacity: Double {
        guard glassEnabled else { return 0.10 }
        return glassIntensity == .enhanced ? 0.13 : 0.09
    }

    var material: Material {
        guard glassEnabled else { return .regular }
        return glassIntensity == .enhanced ? .thin : .ultraThin
    }

    var settingsBackdrop: LinearGradient {
        if !glassEnabled {
            return LinearGradient(
                colors: [
                    Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255),
                    Color(red: 236 / 255, green: 240 / 255, blue: 247 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if glassIntensity == .enhanced {
            return LinearGradient(
                colors: [
                    Color(red: 235 / 255, green: 243 / 255, blue: 255 / 255).opacity(0.22),
                    Color(red: 204 / 255, green: 221 / 255, blue: 245 / 255).opacity(0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 242 / 255, green: 247 / 255, blue: 255 / 255).opacity(0.28),
                Color(red: 220 / 255, green: 230 / 255, blue: 245 / 255).opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

public extension AgentSignal {
    var pulseColor: Color {
        switch self {
        case .idle: AgentPulseColors.idle
        case .thinking: AgentPulseColors.thinking
        case .working, .done: AgentPulseColors.working
        case .attention: AgentPulseColors.attention
        }
    }
}
