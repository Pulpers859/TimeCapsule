import SwiftUI
import UIKit

// MARK: - Palette

extension Color {
    /// Warm amber brand tint. Mirrors the `AccentColor` asset so gradients can
    /// compose with it directly instead of round-tripping the asset catalog.
    static let tcAmber = Color(red: 0.961, green: 0.690, blue: 0.235)
    static let tcRose = Color(red: 0.914, green: 0.376, blue: 0.443)

    /// Fill for grid cells and skeletons. Adapts to light/dark on its own, so
    /// callers never need to branch on color scheme.
    static let tcPlaceholder = Color(.tertiarySystemFill)
}

enum TCGradient {
    /// Used for hero glyphs and the few decorative accents that carry the
    /// brand. Deliberately rare — restraint is what keeps it feeling premium.
    static let brand = LinearGradient(
        colors: [.tcAmber, .tcRose],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Low-opacity version for surfaces that sit behind text.
    static let brandSoft = LinearGradient(
        colors: [Color.tcAmber.opacity(0.20), Color.tcRose.opacity(0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Metrics

enum TCMetrics {
    /// Slight gutter + rounded cells reads as a curated gallery rather than a
    /// contact sheet. 2pt hard-edge grids look like a file browser.
    static let gridSpacing: CGFloat = 3
    static let thumbnailRadius: CGFloat = 10
    static let cardRadius: CGFloat = 24
    static let screenPadding: CGFloat = 16
    static let controlHeight: CGFloat = 44
}

// MARK: - Backgrounds

/// A near-imperceptible warm wash behind the gallery. Flat `systemBackground`
/// reads as an empty sheet; this gives the photos something to sit on without
/// competing with them for attention.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                stops: [
                    .init(color: Color.tcAmber.opacity(0.10), location: 0),
                    .init(color: Color.tcRose.opacity(0.045), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Button styles

/// Gives every tappable surface a little physical give. Applied broadly, this
/// is most of the difference between "functional" and "considered".
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var dims: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed && dims ? 0.75 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Loading

/// Sweeping highlight used for skeleton content. Cheaper and far calmer than a
/// spinner in every grid cell, which reads as noise at gallery scale.
struct ShimmerFill: View {
    @State private var isAnimating = false

    var body: some View {
        Rectangle()
            .fill(Color.tcPlaceholder)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.07), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: isAnimating ? geo.size.width * 1.2 : -geo.size.width * 0.8)
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Skeleton that mirrors the real gallery layout, so the transition into loaded
/// content has no jump.
struct SkeletonGalleryView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 180), spacing: TCMetrics.gridSpacing)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ShimmerFill()
                    .frame(height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: TCMetrics.cardRadius, style: .continuous))
                    .padding(.horizontal, TCMetrics.screenPadding)
                    .padding(.top, 8)

                ForEach(0..<2, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        ShimmerFill()
                            .frame(width: 132, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.horizontal, TCMetrics.screenPadding)
                            .padding(.top, 28)

                        LazyVGrid(columns: columns, spacing: TCMetrics.gridSpacing) {
                            ForEach(0..<(section == 0 ? 6 : 3), id: \.self) { _ in
                                ShimmerFill()
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: TCMetrics.thumbnailRadius,
                                            style: .continuous
                                        )
                                    )
                            }
                        }
                        .padding(.horizontal, TCMetrics.screenPadding)
                    }
                }
            }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding your memories")
    }
}

// MARK: - Shared chrome

/// Circular glass control. Used only where it floats over content — per Apple's
/// guidance, glass belongs to the navigation layer, never to content itself.
struct GlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: TCMetrics.controlHeight, height: TCMetrics.controlHeight)
                .contentShape(Circle())
        }
        .buttonBorderShape(.circle)
        .glassIconStyle(isProminent: isProminent)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension View {
    /// `.glassProminent` is known to render artifacts on circular borders, so
    /// the prominent variant gets an explicit clip.
    @ViewBuilder
    func glassIconStyle(isProminent: Bool) -> some View {
        if isProminent {
            self.buttonStyle(.glassProminent).clipShape(Circle())
        } else {
            self.buttonStyle(.glass)
        }
    }
}

/// A large glyph in a soft branded tile. Anchors the permission and empty
/// screens with something warmer than a plain gray SF Symbol.
struct BrandGlyph: View {
    let systemName: String
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle().fill(TCGradient.brandSoft)
            Circle().strokeBorder(Color.tcAmber.opacity(0.28), lineWidth: 1)
            Image(systemName: systemName)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(TCGradient.brand)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shared layout for the permission, denied, and empty screens so all three
/// read as the same app rather than three separate placeholder designs.
struct EmptyStateScaffold<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    private let actions: Actions

    init(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            BrandGlyph(systemName: symbol)
                .padding(.bottom, 26)

            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 320)
                .padding(.bottom, 28)

            actions

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
