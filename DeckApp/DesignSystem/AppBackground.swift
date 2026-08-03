import SwiftUI

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.015, green: 0.07, blue: 0.13), Color(red: 0.02, green: 0.12, blue: 0.2)]
                        : [Color(red: 0.82, green: 0.92, blue: 1), Color(red: 0.94, green: 0.98, blue: 1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(DesignToken.Color.accent.opacity(colorScheme == .dark ? 0.16 : 0.1))
                    .frame(width: 520)
                    .blur(radius: 110)
                    .offset(x: -260, y: -260)

                Circle()
                    .fill(Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.06))
                    .frame(width: 400)
                    .blur(radius: 100)
                    .offset(x: 300, y: 300)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}
