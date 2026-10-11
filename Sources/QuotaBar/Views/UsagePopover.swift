import AppKit
import SwiftUI

/// The light 185 × 32pt rectangle in Figma is a camera guide, never UI content.
struct UsagePopover: View {
    static let designWidth: CGFloat = 355
    static let designCameraHeight: CGFloat = 32
    static let contentHeight: CGFloat = 184
    private static let horizontalInset: CGFloat = 20
    private static let innerWidth = designWidth - horizontalInset * 2
    let store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usageUpdateAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let snapshot = store.snapshot, let window = snapshot.primary {
                usageContent(window, updatedAt: snapshot.updatedAt)
            } else {
                unavailableContent
            }
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityLabel("刷新失败。\(error)")
            }
        }
        .frame(width: Self.innerWidth, alignment: .leading)
        .padding(Self.horizontalInset)
        .frame(width: Self.designWidth, alignment: .topLeading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            UsageDesignAssets.icon("codex")
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Menu {
                Button("刷新用量") { refresh() }
                    .disabled(store.isRefreshing)
                Divider()
                Button("关于 QuotaBar") { showAbout() }
                Button("退出 QuotaBar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                UsageDesignAssets.icon("more-dots")
                    .resizable()
                    .frame(width: 13, height: 3)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .background(.white.opacity(0.09), in: Circle())
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0), location: 0.2980769277),
                        .init(color: .white.opacity(0), location: 0.7019230723),
                        .init(color: .white, location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.4
                )
                .allowsHitTesting(false)
            }
            .help("更多")
            .accessibilityLabel("更多选项")
        }
        .frame(height: 24)
    }

    private func usageContent(_ window: UsageWindow, updatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(periodDescription(window))
                        .font(UsageDesignAssets.font(16))
                        .accessibilityLabel(window.title)
                        .frame(height: 16)
                    updateLabel(updatedAt)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(window.remainingPercent)")
                        .font(UsageDesignAssets.font(28))
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: .white, location: 0.21875),
                            .init(color: .white.opacity(0.4), location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                        .contentTransition(.numericText(value: Double(window.remainingPercent)))
                        .frame(height: 32)
                    Text("%")
                        .font(UsageDesignAssets.font(16))
                }
                .animation(usageUpdateAnimation, value: window.remainingPercent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("剩余额度 \(window.remainingPercent)%")
            }
            .frame(height: 32)

            SegmentedUsageBar(fraction: window.remainingFraction)
                .frame(width: Self.innerWidth, height: 20)
                .animation(usageUpdateAnimation, value: window.remainingPercent)
                .padding(.top, 12)
                .help("已用 \(window.usedPercent)%")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(window.title)剩余 \(window.remainingPercent)%")

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    UsageDesignAssets.icon("reset")
                        .resizable()
                        .frame(width: 13.03, height: 13.03)
                        .offset(x: 0.18, y: 0.18)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text("重置时间")
                        .font(.custom("PingFangSC-Regular", size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Text(window.resetDate.map(Self.resetFormatter.string(from:)) ?? "暂不可用")
                    .font(window.resetDate == nil
                          ? .custom("PingFangSC-Regular", size: 12)
                          : UsageDesignAssets.font(12))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(height: 16)
            .padding(.top, 16)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 24)
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.lastError != nil ? "暂时无法读取用量"
                 : store.snapshot != nil ? "暂无可用额度" : "正在读取用量")
                .font(.custom("PingFangSC-Regular", size: 12))
            if store.snapshot != nil {
                Text("当前账号未返回 5 小时或周额度")
                    .font(.custom("PingFangSC-Regular", size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            updateLabel(store.snapshot?.updatedAt)
        }
        .frame(height: 96, alignment: .topLeading)
        .padding(.top, 24)
    }

    private func updateLabel(_ updatedAt: Date?) -> some View {
        Group {
            if store.lastError != nil {
                Button(action: refresh) {
                    Text("刷新失败，点击重试").underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .disabled(store.isRefreshing)
                .accessibilityLabel("刷新失败，重试读取 Codex 用量")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updateDescription(updatedAt, now: context.date))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .font(.custom("PingFangSC-Regular", size: 10))
        .lineLimit(1)
        .frame(height: 12)
        .help(updatedAt.map { "上次成功更新：\(Self.resetFormatter.string(from: $0))" } ?? "尚未成功读取用量")
    }

    private func showAbout() {
        let authors = Bundle.main.url(forResource: "Authors", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: authors.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }

    private func refresh() {
        guard !store.isRefreshing else { return }
        Task { await store.refresh() }
    }

    private func periodDescription(_ window: UsageWindow) -> String {
        switch window.durationMinutes {
        case 300: "5-Hour"
        case 10_080: "Weekly"
        case let minutes? where minutes % 60 == 0: "\(minutes / 60)-Hour"
        case let minutes?: "\(minutes)-Min"
        case nil: "Codex"
        }
    }

    private func updateDescription(_ updatedAt: Date?, now: Date) -> String {
        guard let updatedAt else { return store.isRefreshing ? "正在读取用量" : "暂未刷新" }
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        if seconds < 60 { return "刚刚刷新" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前刷新" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时前刷新" }
        return "\(Int(seconds / 86400))天前刷新"
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
        return formatter
    }()
}
