import SwiftUI

// MARK: - 통합 알림 행

struct NotifRow: View {
    let n: NowBarNotification

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: n.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(n.iconColor.swiftColor)
                .frame(width: 24)

            Text(n.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let badge = n.badge, let bc = n.badgeColor {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(bc.swiftColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(bc.swiftColor.opacity(0.18)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
    }
}
