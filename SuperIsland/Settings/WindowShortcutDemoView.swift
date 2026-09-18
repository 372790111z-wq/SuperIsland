import SwiftUI

enum WindowShortcutDemoKind: String {
    case fileTrash
    case windowVisibility

    var title: String {
        self == .fileTrash ? "快捷删除文件" : "隐藏 / 显示所有窗口"
    }
}

/// A self-contained illustration; it never invokes the feature being illustrated.
struct WindowShortcutDemoView: View {
    let kind: WindowShortcutDemoKind
    let accent: Color
    let shortcutLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        WindowShortcutDemoScene(
            kind: kind, accent: accent, shortcutLabel: shortcutLabel,
            phase: phase, reduceMotion: reduceMotion
        )
        .task(id: "\(kind.rawValue)-\(reduceMotion)-\(shortcutLabel ?? "")") {
            phase = 0
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                for next in 1...4 {
                    do {
                        try await Task.sleep(nanoseconds: next == 1 ? 900_000_000 : 1_150_000_000)
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.38)) { phase = next }
                }
                do { try await Task.sleep(nanoseconds: 1_600_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                phase = 0
            }
        }
        .allowsHitTesting(false)
    }
}

/// Explicit phases also allow deterministic, offscreen visual verification.
struct WindowShortcutDemoScene: View {
    let kind: WindowShortcutDemoKind
    let accent: Color
    let shortcutLabel: String?
    let phase: Int
    let reduceMotion: Bool

    private var currentPhase: Int { min(4, max(0, phase)) }
    private var shortcut: String { shortcutLabel ?? "未设置快捷键" }
    private var keyPressed: Bool {
        !reduceMotion && (currentPhase == 1 || (kind == .windowVisibility && currentPhase == 3))
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
            if reduceMotion {
                staticStages
            } else {
                desktop(phase: currentPhase)
                    .frame(height: 142)
            }
            Text(shortcut)
                .font(.system(size: shortcutLabel == nil ? 10 : 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .frame(height: 23)
                .background(keyPressed ? accent.opacity(0.3) : Color.white.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    keyPressed ? accent : Color.white.opacity(0.13), lineWidth: 1
                ))
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.74))
                .multilineTextAlignment(.center)
                .frame(height: 29, alignment: .top)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var staticStages: some View {
        HStack(spacing: 6) {
            staticStage(phase: 0, label: kind == .fileTrash ? "选中文件" : "显示 A、B")
            Image(systemName: kind == .fileTrash ? "arrow.right" : "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(accent)
            staticStage(phase: 2, label: kind == .fileTrash ? "移入废纸篓" : "收起 A、B")
        }
        .frame(height: 142)
    }

    private func staticStage(phase: Int, label: String) -> some View {
        VStack(spacing: 8) {
            desktop(phase: phase).frame(height: 110)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func desktop(phase: Int) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.16), Color.white.opacity(0.045)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                if kind == .fileTrash {
                    fileScene(size: size, trashed: phase >= 2)
                } else {
                    windowScene(size: size, minimized: phase == 2 || phase == 3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func fileScene(size: CGSize, trashed: Bool) -> some View {
        let compact = size.width < 150 || size.height < 125
        return ZStack {
            fileIcon(selected: true, compact: compact)
                .scaleEffect(trashed ? 0.15 : 1)
                .opacity(trashed ? 0 : 1)
                .position(x: size.width * (trashed ? 0.8 : 0.27), y: size.height * (trashed ? 0.76 : 0.36))
            fileIcon(selected: false, compact: compact)
                .position(x: size.width * 0.71, y: size.height * 0.36)
            VStack(spacing: 3) {
                Image(systemName: trashed ? "trash.fill" : "trash")
                    .font(.system(size: compact ? 20 : 25, weight: .regular))
                    .foregroundColor(trashed ? accent : .white.opacity(0.6))
                Text(trashed ? "可恢复" : "废纸篓")
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundColor(.white.opacity(0.7))
            }
            .position(x: size.width * 0.8, y: size.height * 0.79)
        }
    }

    private func fileIcon(selected: Bool, compact: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: compact ? 21 : 28))
                .foregroundColor(selected ? .white.opacity(0.95) : .white.opacity(0.5))
            Text(selected ? "示例文件" : "保留文件")
                .font(.system(size: compact ? 8 : 9, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(compact ? 4 : 7)
        .background(selected ? accent.opacity(0.35) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func windowScene(size: CGSize, minimized: Bool) -> some View {
        let compact = size.width < 150
        return ZStack {
            miniatureWindow("A", color: accent, compact: compact)
                .frame(width: size.width * 0.59, height: size.height * 0.49)
                .scaleEffect(minimized ? 0.12 : 1)
                .opacity(minimized ? 0 : 1)
                .position(x: size.width * (minimized ? 0.23 : 0.38), y: size.height * (minimized ? 0.86 : 0.34))
            miniatureWindow("B", color: Color.purple, compact: compact)
                .frame(width: size.width * 0.51, height: size.height * 0.43)
                .scaleEffect(minimized ? 0.12 : 1)
                .opacity(minimized ? 0 : 1)
                .position(x: size.width * (minimized ? 0.42 : 0.64), y: size.height * (minimized ? 0.86 : 0.53))
            HStack(spacing: compact ? 5 : 10) {
                dockWindow("A", visible: minimized, color: accent)
                dockWindow("B", visible: minimized, color: .purple)
                dockWindow(compact ? "C" : "C 已收起", visible: true, color: .gray)
            }
            .font(.system(size: compact ? 8 : 9, weight: .medium))
            .padding(.horizontal, compact ? 5 : 10)
            .frame(height: 23)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: size.width * 0.5, y: size.height * 0.87)
        }
    }

    private func miniatureWindow(_ name: String, color: Color, compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(Color.white.opacity(0.4)).frame(width: 3, height: 3) }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(Color.white.opacity(0.08))
            Text(name)
                .font(.system(size: compact ? 13 : 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(color.opacity(0.3).background(Color(white: 0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2)))
    }

    private func dockWindow(_ name: String, visible: Bool, color: Color) -> some View {
        Text(name)
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(color.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(visible ? 1 : 0)
    }

    private var caption: String {
        if kind == .fileTrash {
            return reduceMotion || currentPhase >= 2
                ? "移到废纸篓，可恢复\n未选中的文件保持不变"
                : "选中 Finder 或桌面文件\n按下已设置的快捷键"
        }
        if reduceMotion { return "第一次收起，第二次恢复 A、B\n原本已收起的 C 保持不变" }
        switch currentPhase {
        case 1, 2: return "第一次按下：收起 A、B\n原本已收起的 C 保持不变"
        case 3, 4: return "第二次按下：恢复 A、B\n原本已收起的 C 保持不变"
        default: return "A、B 正在显示\nC 原本已收起"
        }
    }

    private var accessibilityDescription: String {
        let steps = kind == .fileTrash
            ? "演示：选中 Finder 或桌面文件，按快捷键移到废纸篓，可恢复；未选中的文件不变。"
            : "演示：第一次按快捷键收起 A、B 窗口，第二次恢复 A、B；原本已收起的 C 窗口保持不变。"
        return "\(steps)快捷键：\(shortcut)。"
    }
}
