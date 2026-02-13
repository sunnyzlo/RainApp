import SwiftUI
import Combine

struct TimeWheel: View {

    @Binding var selectedHour: Int
    var isDarkTheme: Bool = true
    var rainIntensityByHour: [Int: Double] = [:]

    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int?
    @State private var previewHour: Int?
    @State private var now = Date()

    private var hours: [Int] {
        let nowHour = Calendar.current.component(.hour, from: now)
        return (0..<7).map { (nowHour + $0) % 24 }
    }

    var body: some View {

        GeometryReader { geo in

            let horizontalInset: CGFloat = 24
            let trackHeight: CGFloat = 60
            let bubbleHeight: CGFloat = 50
            let cellWidth =
                (geo.size.width - horizontalInset * 2)
                / CGFloat(hours.count)
            let bubbleWidth = max(66, cellWidth + 16)
            let activeHour = previewHour ?? selectedHour
            let isScrubbing = dragStartIndex != nil || abs(dragOffset) > 0.5
            let dragProgress = min(1, abs(dragOffset) / max(1, cellWidth * 0.28))
            let dragDirection: CGFloat = dragOffset == 0 ? 0 : (dragOffset > 0 ? 1 : -1)
            let dragEnergy = CGFloat(pow(Double(dragProgress), 0.72))
            let rainBySlot = hours.map { max(0, rainIntensityByHour[$0] ?? 0) }
            let hourFont = Font.system(size: 18, weight: .bold, design: .rounded)

            ZStack {

                // Track: native material/glass stack (tab-bar like)
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(
                                isDarkTheme
                                    ? Color.black.opacity(0.26)
                                    : Color.white.opacity(0.28)
                            )
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: isDarkTheme
                                        ? [
                                            Color.white.opacity(0.36),
                                            Color.white.opacity(0.08)
                                        ]
                                        : [
                                            Color.white.opacity(0.75),
                                            Color.black.opacity(0.12)
                                        ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .background(
                        Capsule()
                            .fill(
                                isDarkTheme
                                    ? .black.opacity(0.32)
                                    : .white.opacity(0.34)
                            )
                            .blur(radius: 24)
                    )
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(isDarkTheme ? 0.18 : 0.32),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(1.5)
                    )
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)

                // Active bubble:
                // idle => simple gray fill
                // scrubbing => liquid glass + edge distortion
                ZStack {
                    if isScrubbing {
                        Capsule()
                            .glassEffect(.regular.interactive())
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(isDarkTheme ? 0.34 : 0.58), lineWidth: 0.9)
                            )
                            .overlay(
                                Capsule()
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                .white.opacity(isDarkTheme ? 0.26 : 0.42),
                                                .clear
                                            ],
                                            center: .top,
                                            startRadius: 2,
                                            endRadius: 34
                                        )
                                    )
                                    .padding(2)
                            )
                            .overlay(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                .clear,
                                                .cyan.opacity(isDarkTheme ? 0.34 : 0.40),
                                                .yellow.opacity(isDarkTheme ? 0.24 : 0.32),
                                                .clear
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .blur(radius: 16)
                                    .opacity(1.0 * dragEnergy)
                                    .offset(x: dragDirection * 30 * dragEnergy)
                                    .mask(
                                        Capsule()
                                            .stroke(lineWidth: 10)
                                    )
                            )
                            .overlay(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                .clear,
                                                .white.opacity(isDarkTheme ? 0.28 : 0.44),
                                                .clear
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .blur(radius: 13)
                                    .opacity(0.92 * dragEnergy)
                                    .offset(
                                        x: -dragDirection * 17 * dragEnergy,
                                        y: 5 * dragEnergy
                                    )
                                    .mask(
                                        Capsule()
                                            .stroke(lineWidth: 8)
                                    )
                            )
                            .overlay(
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(
                                            AngularGradient(
                                                colors: [
                                                    .clear,
                                                    .red.opacity(isDarkTheme ? 0.92 : 0.84),
                                                    .orange.opacity(isDarkTheme ? 0.76 : 0.68),
                                                    .cyan.opacity(isDarkTheme ? 0.90 : 0.84),
                                                    .blue.opacity(isDarkTheme ? 0.90 : 0.86),
                                                    .clear
                                                ],
                                                center: .center
                                            )
                                        )
                                        .frame(width: bubbleHeight * 0.88, height: bubbleHeight * 0.98)
                                        .blur(radius: 9)
                                        .saturation(1.7)
                                        .offset(
                                            x: -20 - 18 * dragEnergy,
                                            y: -2 - 3 * dragEnergy
                                        )
                                    Spacer(minLength: 0)
                                    Circle()
                                        .fill(
                                            AngularGradient(
                                                colors: [
                                                    .clear,
                                                    .blue.opacity(isDarkTheme ? 0.95 : 0.90),
                                                    .cyan.opacity(isDarkTheme ? 0.88 : 0.82),
                                                    .yellow.opacity(isDarkTheme ? 0.74 : 0.68),
                                                    .red.opacity(isDarkTheme ? 0.90 : 0.82),
                                                    .clear
                                                ],
                                                center: .center
                                            )
                                        )
                                        .frame(width: bubbleHeight * 0.88, height: bubbleHeight * 0.98)
                                        .blur(radius: 9)
                                        .saturation(1.7)
                                        .offset(
                                            x: 20 + 18 * dragEnergy,
                                            y: -2 - 3 * dragEnergy
                                        )
                                }
                                .padding(.horizontal, -20)
                                .opacity(1.0 * dragEnergy)
                                .mask(
                                    Capsule()
                                        .stroke(lineWidth: 14)
                                )
                            )
                    } else {
                        Capsule()
                            .fill(
                                isDarkTheme
                                    ? Color.white.opacity(0.16)
                                    : Color.gray.opacity(0.24)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        isDarkTheme
                                            ? .white.opacity(0.30)
                                            : .black.opacity(0.16),
                                        lineWidth: 0.9
                                    )
                            )
                    }
                }
                .frame(width: bubbleWidth, height: bubbleHeight)
                .padding(.horizontal, 6)
                .offset(
                    x: highlightOffset(cellWidth, activeHour: activeHour)
                )
                .scaleEffect(
                    x: 1 + 0.14 * dragEnergy,
                    y: 1 - 0.08 * dragEnergy
                )
                .rotationEffect(.degrees(Double(dragDirection * dragEnergy * 2.8)))
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.84), value: activeHour)

                // HOURS
                HStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                        Text(index == 0 ? Self.nowTimeFormatter.string(from: now) : "\(hour)")
                            .font(hourFont)
                            .monospacedDigit()
                            .foregroundStyle(isDarkTheme ? Color.white : Color.black)
                            .opacity(hour == activeHour ? 1 : 0.55)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .frame(width: cellWidth)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(hour)
                            }
                    }
                }
                .padding(.horizontal, horizontalInset)
                .frame(maxWidth: .infinity)

                rainLineOverlay(
                    rainBySlot: rainBySlot,
                    horizontalInset: horizontalInset,
                    cellWidth: cellWidth,
                    trackHeight: trackHeight
                )

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()

                    .onChanged { value in

                        dragOffset = value.translation.width

                        // ⭐ фиксируем старт только один раз
                        if dragStartIndex == nil {
                            dragStartIndex =
                                hours.firstIndex(of: selectedHour)
                        }

                        guard let startIndex = dragStartIndex else { return }

                        let shift =
                            Int(round(dragOffset / cellWidth))

                        let newIndex =
                            (startIndex + shift)
                                .clamped(to: 0...hours.count-1)

                        let newHour = hours[newIndex]
                        previewHour = newHour

                        // Apply immediately while scrubbing, without waiting for finger release.
                        if newHour != selectedHour {
                            selectedHour = newHour
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }

                    .onEnded { _ in
                        dragStartIndex = nil
                        previewHour = nil

                        withAnimation(.interactiveSpring(
                            response: 0.35,
                            dampingFraction: 0.75
                        )) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .frame(height: 64)
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

    private func highlightOffset(_ width: CGFloat, activeHour: Int) -> CGFloat {

        guard let index = hours.firstIndex(of: activeHour)
        else { return 0 }

        return CGFloat(index) * width
            - width * CGFloat(hours.count - 1) / 2
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

    @ViewBuilder
    private func rainLineOverlay(
        rainBySlot: [Double],
        horizontalInset: CGFloat,
        cellWidth: CGFloat,
        trackHeight: CGFloat
    ) -> some View {
        let rainyThreshold = 0.02
        let dotY: CGFloat = 7.5

        Canvas { context, _ in
            func normalize(_ intensity: Double) -> CGFloat {
                min(1.0, max(0.0, intensity / 3.0))
            }

            func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
                a + (b - a) * t
            }

            func rainDotColor(_ normalized: CGFloat) -> Color {
                if isDarkTheme {
                    return Color(
                        red: lerp(0.24, 0.05, normalized),
                        green: lerp(0.66, 0.30, normalized),
                        blue: lerp(1.00, 0.78, normalized)
                    )
                }
                return Color(
                    red: lerp(0.20, 0.04, normalized),
                    green: lerp(0.62, 0.34, normalized),
                    blue: lerp(0.98, 0.82, normalized)
                )
            }

            func x(_ index: Int) -> CGFloat {
                horizontalInset + CGFloat(index) * cellWidth + cellWidth / 2
            }

            for index in rainBySlot.indices {
                let intensity = rainBySlot[index]
                guard intensity > rainyThreshold else { continue }

                let normalized = normalize(intensity)
                let dotRadius = 2.8 + normalized * 3.0
                let center = CGPoint(x: x(index), y: dotY)
                let dotRect = CGRect(
                    x: center.x - dotRadius,
                    y: center.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                let color = rainDotColor(normalized)

                var dot = Path()
                dot.addEllipse(in: dotRect)
                context.fill(dot, with: .color(color.opacity(0.96)))
            }
        }
        .frame(height: trackHeight)
        .allowsHitTesting(false)
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

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
