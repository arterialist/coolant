import SwiftUI

/// Icy cyan from the app icon's ring.
let brandTint = Color(red: 0.38, green: 0.86, blue: 0.96)

extension View {
    /// Liquid Glass on macOS 26 and later, a standard material before that.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #else
        background(.regularMaterial, in: shape)
        #endif
    }

    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
        #else
        buttonStyle(.bordered)
        #endif
    }
}

/// Soft colour for the glass to pick up, taken from the two ends of the icon's ring.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [brandTint.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color.orange.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(spacing: 10) { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 26)
    }
}
