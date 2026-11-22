// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// The colours and controls the JIT setup screens are written against.
///
/// Trimmed from Henge's Theme.swift for the Phase 4 port: only what
/// JITSetupView uses (Desk's tones, Theme, the card modifier and the two
/// button styles). Henge's Desk extras (appearance setting, Mac previews,
/// session furniture) have no counterpart in this app and are not ported.
enum Desk {
    static let page = tone(light: (242, 243, 247), dark: (11, 12, 16))
    static let card = tone(light: (255, 255, 255), dark: (22, 24, 31))
    static let raised = tone(light: (228, 230, 236), dark: (35, 38, 47))
    static let text = tone(light: (17, 19, 24), dark: (242, 243, 247))
    static let dim = tone(light: (92, 97, 112), dark: (144, 149, 164))
    static let accent = Color(red: 46 / 255, green: 107 / 255, blue: 1)
    static let hairline = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.1) })

    private static func tone(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        func ui(_ c: (Int, Int, Int)) -> UIColor {
            UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        let l = ui(light), d = ui(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}

/// The names the JIT setup screens (from Husk) use, in Henge's colours.
enum Theme {
    static let accent = Desk.accent
    static let accentSoft = Desk.accent.opacity(0.18)
    static let backdrop = Desk.page
    static let text = Desk.text
    static let textDim = Desk.dim
}

extension View {
    /// high: a card raised above the others (a result, an outcome).
    func hengeCard(high: Bool = false) -> some View {
        background(high ? Desk.raised : Desk.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Desk.hairline, lineWidth: 1))
    }

    /// Husk's screens are written against an iOS 15 shim; this app needs iOS 17, so this is the real thing.
    func hengeDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}

/// The one action a screen is for (the JIT setup screens use it).
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Desk.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(enabled ? Desk.accent : Desk.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A card that is also a button: it moves a little under the finger.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
