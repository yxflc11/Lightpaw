import SwiftUI

enum PawTheme {
    static let background = Color(white: 0.16)
    static let sidebar = Color(white: 0.12)
    static let accent = Color(red: 0.80, green: 0.72, blue: 0.88)
    static let lavender = accent
    static let text = Color(white: 0.92)
    static let secondary = Color(white: 0.68)
    static let separator = Color.white.opacity(0.10)
}

struct CatLogo: View {
    var size: CGFloat = 18
    private static let smallMark = BrandIcon.image(size: 18)
    private static let sidebarMark = BrandIcon.image(size: 27)
    var body: some View {
        Image(nsImage: size > 20 ? Self.sidebarMark : Self.smallMark).resizable().interpolation(.high)
            .frame(width: size, height: size).foregroundStyle(PawTheme.accent)
            .accessibilityLabel("Lightpaw 小猫")
    }
}

struct DottedMeter: View {
    let fraction: Double?
    var tint: Color = PawTheme.accent
    var height: CGFloat = 8
    var body: some View {
        Canvas { context, size in
            let fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            let filled = size.width * CGFloat(fraction ?? 0)
            for y in stride(from: 1.0, to: size.height, by: 3.0) {
                for x in stride(from: 1.0, to: size.width, by: 3.0) where x >= filled {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(tint.opacity(0.5)))
                }
            }
            if fraction != nil {
                context.fill(Path(CGRect(x: 0, y: 0, width: filled, height: size.height)), with: .color(tint))
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct AnimatedCat: View {
    let active: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var pose = BrandIcon.Pose.rest
    private var moving: Bool { active && !reduceMotion }
    private static let frames = BrandIcon.Pose.allCases.map(BrandIcon.mascotImage)
    var body: some View {
        Image(nsImage: Self.frames[(moving ? pose : .rest).rawValue])
            .resizable().interpolation(.high)
            .frame(width: compact ? 80 : 100, height: compact ? 56 : 70)
            .foregroundStyle(PawTheme.lavender)
            .accessibilityLabel("Lightpaw 小猫")
            .accessibilityIdentifier("lightpaw-cat")
            .task(id: moving) {
                pose = .rest
                guard moving else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 2_800_000_000)
                        pose = .blink
                        try await Task.sleep(nanoseconds: 160_000_000)
                        pose = .rest
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        pose = .tailUp
                        try await Task.sleep(nanoseconds: 240_000_000)
                        pose = .tailDown
                        try await Task.sleep(nanoseconds: 240_000_000)
                        pose = .rest
                    }
                } catch { pose = .rest }
            }
    }
}
