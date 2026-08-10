import SwiftUI

extension View {
    /// Apple Liquid Glass (macOS 26) with a graceful material fallback,
    /// kept in one place so styling stays consistent.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
