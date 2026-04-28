import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(spacing: 10) {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nowbar")
                        .font(.system(size: 15, weight: .bold))
                    Text("실행 중")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // 설정 버튼
            SettingsRow(icon: "gearshape.fill", label: "설정") {
                // 나중에 설정 창 열기
            }

            Divider()
                .padding(.horizontal, 16)

            // 종료 버튼
            SettingsRow(icon: "power", label: "Nowbar 종료", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }

            Divider()
        }
        .frame(width: 220)
    }
}

// MARK: - 설정 행 컴포넌트
private struct SettingsRow: View {
    let icon: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovered = false

    var labelColor: Color {
        role == .destructive ? .red : .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(labelColor)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
