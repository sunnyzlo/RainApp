import SwiftUI
import Combine

struct TimeWheel: View {

    private static let slotCount = 12 // now + next 11 hours (was 7)

    @Binding var selectedHour: Int
    var isDarkTheme: Bool = true
    var cloudDotColorByHour: [Int: Color] = [:]
    @Binding var isScrubbing: Bool
    var embeddedInContainer: Bool = false

    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int?
    @State private var previewHour: Int?
    @State private var now = Date()

    private var hours: [Int] {
        let nowHour = Calendar.current.component(.hour, from: now)
        return (0..<Self.slotCount).map { (nowHour + $0) % 24 }
    }

    var body: some View {

        GeometryReader { geo in

            let horizontalInset: CGFloat = 20
            let trackHeight: CGFloat = 48
            let bubbleHeight: CGFloat = 38
            let firstCellExtraWidth: CGFloat = 20
            let contentWidth = max(1, geo.size.width - horizontalInset * 2)
            let baseCellWidth =
                (contentWidth - firstCellExtraWidth)
                / CGFloat(hours.count)
            let slotWidths = hours.enumerated().map { index, _ in
                index == 0 ? (baseCellWidth + firstCellExtraWidth) : baseCellWidth
            }
            let slotCenters: [CGFloat] = {
                var centers: [CGFloat] = []
                var x: CGFloat = 0
                for width in slotWidths {
                    centers.append(x + width / 2)
                    x += width
                }
                return centers
            }()
            let activeHour = previewHour ?? selectedHour
            let isScrubbingActive = dragStartIndex != nil || abs(dragOffset) > 0.5
            let dragProgress = min(1, abs(dragOffset) / max(1, baseCellWidth * 0.28))
            let dragDirection: CGFloat = dragOffset == 0 ? 0 : (dragOffset > 0 ? 1 : -1)
            let dragEnergy = CGFloat(pow(Double(dragProgress), 0.72))
            let hourFont = Font.system(size: 14, weight: .semibold, design: .rounded)
            let bubbleWidth = max(50, baseCellWidth + 6)
            let activeIndex = max(0, hours.firstIndex(of: activeHour) ?? 0)
            let activeCenter = slotCenters[min(activeIndex, max(0, slotCenters.count - 1))]
            let centerOffset = contentWidth / 2
            let cloudDotColors = hours.map { cloudDotColorByHour[$0] }

            ZStack {

                if !embeddedInContainer {
                    Group {
                        if #available(iOS 26.0, *) {
                            Capsule()
                                .fill(isDarkTheme ? .clear : Color.black.opacity(0.08))
                                .glassEffect(.regular)
                                .overlay(
                                    Capsule()
                                        .stroke(.white.opacity(isDarkTheme ? 0.22 : 0.12), lineWidth: 1)
                                )
                        } else {
                            Capsule()
                                .fill(.ultraThinMaterial)
                        }
                    }
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)
                }

                // Active bubble:
                ZStack {
                    Group {
                        if #available(iOS 26.0, *) {
                            Capsule()
                                .fill(
                                    isDarkTheme
                                        ? Color.white.opacity(isScrubbingActive ? 0.16 : 0.24)
                                        : Color.black.opacity(isScrubbingActive ? 0.16 : 0.26)
                                )
                                .glassEffect(isScrubbingActive ? .regular.interactive() : .regular)
                                .overlay(
                                    Capsule()
                                        .stroke(.white.opacity(isScrubbingActive ? 0.24 : 0.0), lineWidth: 1)
                                )
                        } else {
                            Capsule()
                                .fill(
                                    isDarkTheme
                                        ? Color.white.opacity(isScrubbingActive ? 0.20 : 0.24)
                                        : Color.black.opacity(isScrubbingActive ? 0.20 : 0.26)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            isDarkTheme
                                                ? .white.opacity(isScrubbingActive ? 0.22 : 0.0)
                                                : .black.opacity(isScrubbingActive ? 0.18 : 0.0),
                                            lineWidth: 1
                                        )
                                )
                        }
                    }
                }
                .frame(width: bubbleWidth, height: bubbleHeight)
                .padding(.horizontal, 6)
                .offset(
                    x: activeCenter - centerOffset
                )
                .scaleEffect(
                    x: 1 + 0.08 * dragEnergy,
                    y: 1 - 0.04 * dragEnergy
                )
                .rotationEffect(.degrees(Double(dragDirection * dragEnergy * 1.2)))
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.84), value: activeHour)

                // HOURS
                HStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                        Text(index == 0 ? "Now" : "\(hour)")
                            .font(hourFont)
                            .monospacedDigit()
                            .foregroundStyle(isDarkTheme ? Color.white : Color.black)
                            .opacity(hour == activeHour ? 1 : 0.55)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .frame(width: slotWidths[index])
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(hour)
                            }
                    }
                }
                .padding(.horizontal, horizontalInset)
                .frame(maxWidth: .infinity)

                rainLineOverlay(
                    cloudDotColors: cloudDotColors,
                    horizontalInset: horizontalInset,
                    slotWidths: slotWidths,
                    trackHeight: trackHeight
                )

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()

                    .onChanged { value in

                        dragOffset = value.translation.width
                        isScrubbing = true

                        // ⭐ фиксируем старт только один раз
                        if dragStartIndex == nil {
                            dragStartIndex =
                                hours.firstIndex(of: selectedHour)
                        }

                        guard let startIndex = dragStartIndex else { return }

                        let startCenter = slotCenters[startIndex]
                        let projectedCenter = startCenter + dragOffset
                        let nearestIndex = slotCenters.enumerated().min(by: { lhs, rhs in
                            abs(lhs.element - projectedCenter) < abs(rhs.element - projectedCenter)
                        })?.offset ?? startIndex

                        let newIndex = nearestIndex.clamped(to: 0...hours.count-1)

                        let newHour = hours[newIndex]
                        previewHour = newHour

                        // Apply immediately while scrubbing, without waiting for finger release.
                        if newHour != selectedHour {
                            selectedHour = newHour
                        }
                    }

                    .onEnded { _ in
                        dragStartIndex = nil
                        previewHour = nil
                        isScrubbing = false

                        UIImpactFeedbackGenerator(style: .light).impactOccurred()

                        withAnimation(.interactiveSpring(
                            response: 0.35,
                            dampingFraction: 0.75
                        )) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .frame(height: 50)
        .onReceive(Self.clockTimer) { value in
            now = value
            if !hours.contains(selectedHour) {
                selectedHour = hours.first ?? selectedHour
            }
        }

        .onAppear {
            now = Date()
            if !hours.contains(selectedHour) {
                selectedHour = hours.first ?? 0
            }
        }
    }

    private func select(_ hour: Int) {

        guard hour != selectedHour else { return }
        previewHour = nil

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        withAnimation(.interactiveSpring(
            response: 0.35,
            dampingFraction: 0.75
        )) {
            selectedHour = hour
        }
    }

    private static let nowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let clockTimer = Timer.publish(
        every: 30,
        on: .main,
        in: .common
    ).autoconnect()
}

extension TimeWheel {
    @ViewBuilder
    private func rainLineOverlay(
        cloudDotColors: [Color?],
        horizontalInset: CGFloat,
        slotWidths: [CGFloat],
        trackHeight: CGFloat
    ) -> some View {
        let dotY: CGFloat = 7.5

        Canvas { context, _ in
            func x(_ index: Int) -> CGFloat {
                let before = slotWidths.prefix(index).reduce(0, +)
                return horizontalInset + before + slotWidths[index] / 2
            }

            for index in cloudDotColors.indices {
                guard let color = cloudDotColors[index] else { continue }

                let dotRadius: CGFloat = 3.6
                let center = CGPoint(x: x(index), y: dotY)
                let dotRect = CGRect(
                    x: center.x - dotRadius,
                    y: center.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )

                var dot = Path()
                dot.addEllipse(in: dotRect)
                context.fill(dot, with: .color(color))
                context.stroke(
                    dot,
                    with: .color(isDarkTheme ? .black.opacity(0.22) : .black.opacity(0.18)),
                    lineWidth: 0.9
                )
            }
        }
        .frame(height: trackHeight)
        .allowsHitTesting(false)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
