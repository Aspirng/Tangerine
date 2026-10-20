import SwiftUI

/// One pie slice between `startAngle` and `endAngle`, with a hole in the
/// middle (`innerRadius`) so wedges form a ring rather than a filled disc.
private struct WedgeShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addLine(to: point(on: innerRadius, angle: endAngle, center: center))
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func point(on radius: CGFloat, angle: Angle, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle.radians), y: center.y + radius * sin(angle.radians))
    }
}

/// The radial conversion menu: an inner ring (shows the drag's file count)
/// surrounded by an outer ring of wedges, one per target format. Purely
/// visual — hit-testing for drag-and-drop is done by the transparent
/// AppKit `WedgeHitView`s layered on top in `OverlayPanel`, which report
/// the hovered wedge back into `hoveredFormat`.
struct RadialMenuView: View {
    let formats: [ConversionFormat]
    let fileCount: Int
    var hoveredFormat: ConversionFormat?

    static let diameter: CGFloat = 280
    static let innerRadius: CGFloat = 50
    static let outerRadius: CGFloat = 130

    var body: some View {
        let count = max(formats.count, 1)
        let angleStep = 360.0 / Double(count)

        ZStack {
            ForEach(Array(formats.enumerated()), id: \.element.id) { index, format in
                let start = Angle(degrees: angleStep * Double(index) - 90 - angleStep / 2)
                let end = Angle(degrees: angleStep * Double(index + 1) - 90 - angleStep / 2)
                let isHovered = hoveredFormat == format

                // Material alone (.ultraThinMaterial) leans on whatever's
                // behind the overlay for contrast — over a plain/light
                // desktop background, unhovered wedges could end up nearly
                // invisible, reading as "fewer wedges than expected" even
                // though all of them are there. The opacity-tinted fill
                // underneath gives every wedge a visibility floor that
                // doesn't depend on the desktop behind it.
                WedgeShape(startAngle: start, endAngle: end, innerRadius: Self.innerRadius, outerRadius: Self.outerRadius)
                    .fill(Color.black.opacity(0.35))
                    .background(
                        WedgeShape(startAngle: start, endAngle: end, innerRadius: Self.innerRadius, outerRadius: Self.outerRadius)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        WedgeShape(startAngle: start, endAngle: end, innerRadius: Self.innerRadius, outerRadius: Self.outerRadius)
                            .stroke(isHovered ? Color.orange : Color.white.opacity(0.45), lineWidth: isHovered ? 3 : 1.5)
                    )
                    .shadow(color: .black.opacity(isHovered ? 0.3 : 0), radius: 8)
                    .scaleEffect(isHovered ? 1.06 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHovered)

                wedgeLabel(format: format, start: start, end: end, isHovered: isHovered)
            }

            Circle()
                .fill(Color.black.opacity(0.4))
                .background(Circle().fill(.ultraThinMaterial))
                .frame(width: Self.innerRadius * 2, height: Self.innerRadius * 2)
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))

            VStack(spacing: 2) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 20))
                Text(fileCount > 1 ? "\(fileCount) files" : "1 file")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }

    private func wedgeLabel(format: ConversionFormat, start: Angle, end: Angle, isHovered: Bool) -> some View {
        let midAngle = (start.radians + end.radians) / 2
        let midRadius = (Self.innerRadius + Self.outerRadius) / 2
        let center = Self.diameter / 2

        return Text(format.label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            // Fixed white, not `.primary`: the wedge background is always
            // darkened for contrast (see the wedge fill above) regardless
            // of system appearance, so label color shouldn't flip with it.
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHovered)
            .position(
                x: center + midRadius * cos(midAngle),
                y: center + midRadius * sin(midAngle)
            )
    }
}
