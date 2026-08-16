//
//  GlassCompat.swift
//  Skylight AR
//
//  Back-deployment layer for Liquid Glass. The design language is built on
//  iOS 26's `glassEffect`; this shim keeps that exact look on iOS 26+ while
//  giving iOS 18–25 a native material fallback. Call sites read identically to
//  the real API — `.glassEffectCompat(.regular.tint(x), in: .capsule)` — so the
//  UI code never branches on OS version.
//

import SwiftUI

// MARK: - Glass description

/// Version-agnostic mirror of the iOS 26 `Glass` value. Exposes the same
/// fluent surface (`.regular` / `.clear`, `.tint(_:)`, `.interactive()`) so it
/// can be constructed on any deployment target, then resolved to the native
/// `Glass` only where it's actually available.
struct GlassCompat {
    enum Base { case regular, clear }

    var base: Base
    var tint: Color? = nil
    var isInteractive: Bool = false

    static let regular = GlassCompat(base: .regular)
    static let clear = GlassCompat(base: .clear)

    func tint(_ color: Color) -> GlassCompat {
        var copy = self
        copy.tint = color
        return copy
    }

    func interactive() -> GlassCompat {
        var copy = self
        copy.isInteractive = true
        return copy
    }
}

@available(iOS 26.0, *)
private extension GlassCompat {
    /// Rebuild the native `Glass` value this description stands in for.
    var native: Glass {
        var glass: Glass = (base == .clear) ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - View modifier

extension View {
    /// Drop-in replacement for `.glassEffect(_:in:)`. Real Liquid Glass on
    /// iOS 26+; a native material surface on iOS 18–25.
    @ViewBuilder
    func glassEffectCompat<S: Shape>(_ glass: GlassCompat = .regular, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(glass.native, in: shape)
        } else {
            self.modifier(GlassFallbackModifier(glass: glass, shape: shape))
        }
    }

    /// Shapeless convenience — matches `glassEffect`'s default capsule.
    @ViewBuilder
    func glassEffectCompat(_ glass: GlassCompat = .regular) -> some View {
        glassEffectCompat(glass, in: Capsule())
    }
}

/// iOS 18–25 stand-in for a glass surface: a system material fill carrying the
/// tint, finished with a hairline edge. Deliberately restrained — a material is
/// the platform-native way to read as frosted glass without faking blur, and it
/// keeps the monochrome-plus-one-accent discipline intact.
private struct GlassFallbackModifier<S: Shape>: ViewModifier {
    let glass: GlassCompat
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            shape
                .fill(glass.base == .clear ? AnyShapeStyle(.ultraThinMaterial)
                                           : AnyShapeStyle(.regularMaterial))
                .overlay { if let tint = glass.tint { shape.fill(tint) } }
                .overlay { shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5) }
        }
    }
}

// MARK: - Container

/// Stand-in for `GlassEffectContainer`. On iOS 26+ it groups glass so shapes can
/// morph and blend; on iOS 18–25 there's no shared glass layer, so it simply
/// renders its content — every child already draws its own material fallback.
struct GlassEffectContainerCompat<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
