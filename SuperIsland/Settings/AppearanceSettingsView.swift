import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    // Canonical defaults — source of truth for the per-section Reset buttons
    // and for the @AppStorage initial values in AppState.
    private enum Defaults {
        static let bounceAmount: Double = 0.25
        static let animationLevel = AnimationLevel.full
        static let reduceMotion = false
        static let compactIslandWidth: Double = 200
        static let compactIslandHeight: Double = 36
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            section(
                title: "动画",
                reset: {
                    appState.animationLevel = Defaults.animationLevel
                    appState.reduceMotion = Defaults.reduceMotion
                    appState.bounceAmount = Defaults.bounceAmount
                }
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("动画强度").font(.system(size: 13))
                        Text("控制动态岛运动和过渡强度")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $appState.animationLevelRaw) {
                        ForEach(AnimationLevel.allCases) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                SettingRowDivider()
                SettingToggleRow(
                    title: "减少动态效果",
                    description: "Simplify island transitions and content swaps",
                    isOn: $appState.reduceMotion
                )

                SettingRowDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("弹性").font(.system(size: 13))
                        Text("紧凑与展开切换时的弹性强度")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.bounceAmount,
                        step: 0.05,
                        range: 0.0...0.5
                    ) { "\(Int(($0 * 100).rounded()))%" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            section(
                title: "紧凑动态岛尺寸",
                reset: {
                    appState.compactIslandWidth = Defaults.compactIslandWidth
                    appState.compactIslandHeight = Defaults.compactIslandHeight
                }
            ) {
                sizeRow(
                    title: "宽度",
                    description: "Pill width on notched Macs",
                    value: $appState.compactIslandWidth,
                    step: 2,
                    range: 140...320,
                    unit: "pt"
                )
                SettingRowDivider()
                sizeRow(
                    title: "高度",
                    description: "Pill height on notched Macs",
                    value: $appState.compactIslandHeight,
                    step: 1,
                    range: 28...60,
                    unit: "pt"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        reset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SettingSectionLabel(title: title)
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
        }
        SettingGroup {
            content()
        }
    }

    private func sizeRow(
        title: String,
        description: String,
        value: Binding<Double>,
        step: Double,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: value,
                step: step,
                range: range
            ) { "\(Int($0.rounded())) \(unit)" }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
