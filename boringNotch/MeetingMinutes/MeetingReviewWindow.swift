//
//  MeetingReviewWindow.swift
//  boringNotch
//
//  会议回看窗口：音频播放 + 歌词式转录 + 总结展示
//

import AVFoundation
import SwiftUI

// MARK: - 回看窗口控制器

@MainActor
class MeetingReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = MeetingReviewWindowController()

    private struct Session {
        let controller: NSWindowController
        let player: MeetingAudioPlayer
    }

    private var sessions: [UUID: Session] = [:]

    func showWindow(for meeting: MeetingRecord) {
        // 该会议已开窗 → 直接聚焦
        if let existing = sessions[meeting.id] {
            existing.controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let player = MeetingAudioPlayer()
        let reviewView = MeetingReviewView(meeting: meeting, player: player)
        let hostingController = NSHostingController(rootView: reviewView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = meeting.title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 560))
        window.minSize = NSSize(width: 500, height: 400)

        // 级联定位：水平居中 + 已开窗数量 * 24pt 偏移，避免窗口完全重叠
        if let vf = NSScreen.main?.visibleFrame {
            let size = window.frame.size
            let topGap: CGFloat = 240
            let cascade = CGFloat(sessions.count) * 24
            let x = vf.midX - size.width / 2 + cascade
            let y = max(vf.minY + 20, vf.maxY - topGap - size.height - cascade)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.isReleasedWhenClosed = false
        // 用 meeting id 标记窗口，关窗时靠它找回对应 session
        window.identifier = NSUserInterfaceItemIdentifier(meeting.id.uuidString)
        window.delegate = self
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.isExcludedFromWindowsMenu = false

        NSApp.setActivationPolicy(.regular)

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sessions[meeting.id] = Session(controller: controller, player: player)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let idString = window.identifier?.rawValue,
              let uuid = UUID(uuidString: idString)
        else { return }

        sessions[uuid]?.player.stop()
        sessions.removeValue(forKey: uuid)

        // 所有回看窗口关完后才收起 Dock 图标
        if sessions.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - 回看视图

struct MeetingReviewView: View {
    @ObservedObject var player: MeetingAudioPlayer
    @ObservedObject private var meetingManager = MeetingManager.shared
    @State private var selectedTab = 0
    @State private var draftTitle = ""
    @State private var isHoveringTitle = false
    @State private var isEditingTitle = false
    @State private var showResummarizeConfirm = false
    @State private var userIsScrolling = false
    @FocusState private var titleFocused: Bool

    private let initialMeeting: MeetingRecord

    init(meeting: MeetingRecord, player: MeetingAudioPlayer) {
        self.initialMeeting = meeting
        self.player = player
    }

    // 优先展示历史里的最新版本（支持重命名后实时刷新）
    private var meeting: MeetingRecord {
        meetingManager.meetingHistory.first(where: { $0.id == initialMeeting.id }) ?? initialMeeting
    }

    // 「总结 / 智能章节 / 文字记录」三者之一为空、且当前不在处理中时，
    // 右下角常驻一个克制的「重新总结」入口，方便对内容不全的会议补跑妙记。
    private var needsResummarize: Bool {
        guard meeting.status != .processing else { return false }
        let noSummary = meeting.summary?.fullSummary?.isEmpty ?? true
        let noChapters = meeting.summary?.chapters?.isEmpty ?? true
        let noTranscript = meeting.segments.isEmpty
        return noSummary || noChapters || noTranscript
    }

    // 右下角浮层按钮：材质胶囊 + sparkles 图标，低调不抢视觉
    private var resummarizeButton: some View {
        Button {
            showResummarizeConfirm = true
        } label: {
            Label("重新总结", systemImage: "sparkles")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(20)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            // 顶部：会议信息
            headerView
                .padding()

            Divider()

            // 播放器控制栏
            playerControls
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            // 标签页切换
            Picker("", selection: $selectedTab) {
                Text("总结与待办").tag(0)
                Text("智能章节").tag(1)
                Text("文字记录").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            // 内容区域
            switch selectedTab {
            case 0:
                summaryView
            case 1:
                chaptersView
            case 2:
                transcriptView
            default:
                EmptyView()
            }
        }

            if needsResummarize {
                resummarizeButton
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            loadAudio()
        }
        .onDisappear {
            player.stop()
        }
        .confirmationDialog("重新总结这次会议？", isPresented: $showResummarizeConfirm, titleVisibility: .visible) {
            Button("重新总结") { Task { await meetingManager.summarizeMeeting(meeting) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将重新上传录音并调用妙记，覆盖现有的总结 / 章节 / 待办，并消耗妙记额度。")
        }
    }

    // MARK: - 会议信息头

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                titleView
                HStack(spacing: 12) {
                    Label(meeting.formattedDate, systemImage: "calendar")
                    Label(meeting.formattedDuration, systemImage: "clock")
                    Label("\(meeting.segments.count) 句", systemImage: "text.bubble")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            // 导出按钮
            Menu {
                Button("导出为文本") { exportAsText() }
                Button("导出为 SRT 字幕") { exportAsSRT() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - 播放器控制

    private var playerControls: some View {
        VStack(spacing: 6) {
            // 进度条
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .accentColor(.effectiveAccent)

            HStack {
                Text(formatTime(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()

                // 播放/暂停
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Spacer()
                Text(formatTime(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 歌词式转录视图

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(meeting.segments) { segment in
                        TranscriptLineView(
                            segment: segment,
                            isActive: isSegmentActive(segment),
                            onTap: {
                                userIsScrolling = false
                                player.seek(to: segment.startTime)
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding()
            }
            .onScrollWheelOrTrackpad { userIsScrolling = true }
            .onChange(of: player.currentTime) { _, _ in
                guard !userIsScrolling else { return }
                if let activeSegment = meeting.segments.first(where: { isSegmentActive($0) }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(activeSegment.id, anchor: .center)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if userIsScrolling, meeting.segments.contains(where: { isSegmentActive($0) }) {
                Button {
                    userIsScrolling = false
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.callout.weight(.medium))
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .padding(12)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: userIsScrolling)
    }

    private func isSegmentActive(_ segment: TranscriptSegment) -> Bool {
        player.currentTime >= segment.startTime && player.currentTime < segment.endTime
    }

    // 标题：默认纯文本，hover 渐显可编辑轮廓，点击进入 inline 编辑
    private var titleView: some View {
        Group {
            if isEditingTitle {
                TextField("会议名称", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditingTitle = false }
            } else {
                Text(meeting.title)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isEditingTitle ? 0.06 : (isHoveringTitle ? 0.04 : 0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(isEditingTitle ? 0.5 : (isHoveringTitle ? 0.25 : 0)), lineWidth: 1)
                )
        )
        .frame(maxWidth: 380, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: isHoveringTitle)
        .animation(.easeInOut(duration: 0.15), value: isEditingTitle)
        .onHover { isHoveringTitle = $0 }
        .onTapGesture {
            guard !isEditingTitle else { return }
            draftTitle = meeting.title
            isEditingTitle = true
            titleFocused = true
        }
    }

    private func commitRename() {
        meetingManager.renameMeeting(meeting, newTitle: draftTitle)
        isEditingTitle = false
    }

    // MARK: - 总结视图

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 处理中时顶部显示进度条；其余缺内容状态由右下角「重新总结」浮层承接
                if meeting.status == .processing {
                    processingBanner
                }

                if let summary = meeting.summary {
                    if let fullSummary = summary.fullSummary {
                        SummarySection(title: "总结") {
                            // 逐行解析 Markdown 渲染，排版更透气、更接近苹果阅读风格
                            SummaryMarkdownView(raw: fullSummary)
                        }
                    }

                    if let todos = summary.todoItems, !todos.isEmpty {
                        SummarySection(title: "待办") {
                            ForEach(todos) { todo in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        renderInlineMarkdown(todo.content)
                                            .font(.system(size: 13))
                                            .lineSpacing(5)
                                        if let assignee = todo.assignee {
                                            Text("负责人: \(assignee)")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let qas = summary.qaItems, !qas.isEmpty {
                        SummarySection(title: "问答") {
                            ForEach(qas) { qa in
                                VStack(alignment: .leading, spacing: 3) {
                                    renderInlineMarkdown("Q: \(qa.question)")
                                        .font(.system(size: 13, weight: .medium))
                                        .lineSpacing(5)
                                    renderInlineMarkdown("A: \(qa.answer)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(5)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } else {
                    emptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "暂无总结",
                        subtitle: "配置豆包 API 后，会议结束时将自动生成总结"
                    )
                }
            }
            .padding()
        }
    }

    // 处理中横幅：只在妙记跑任务期间显示进度，不承载任何按钮
    private var processingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在总结，生成文字记录、智能章节与待办…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - 智能章节视图

    private var chaptersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let chapters = meeting.summary?.chapters, !chapters.isEmpty {
                    ForEach(chapters) { chapter in
                        Button {
                            player.seek(to: chapter.startTime)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    renderInlineMarkdown(chapter.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(formatTime(chapter.startTime))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if !chapter.summary.isEmpty {
                                    renderInlineMarkdown(chapter.summary)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    emptyStateView(
                        icon: "list.bullet.rectangle",
                        title: "暂无章节",
                        subtitle: "妙记生成智能章节后将显示在这里"
                    )
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 音频加载

    private func loadAudio() {
        if let localPath = meeting.localAudioPath {
            player.load(url: URL(fileURLWithPath: localPath))
        } else if let objectKey = meeting.audioObjectKey,
                  let presignedURL = TOSStorageService.shared.presignedURL(objectKey: objectKey)
        {
            player.load(url: presignedURL)
        }
    }

    // MARK: - 导出

    private func exportAsText() {
        let text = meeting.segments.map { segment in
            let timeStr = formatTime(segment.startTime)
            let speaker = segment.speaker.map { "[\($0)] " } ?? ""
            return "[\(timeStr)] \(speaker)\(segment.text)"
        }.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meeting.title).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportAsSRT() {
        var srt = ""
        for (index, segment) in meeting.segments.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(srtTime(segment.startTime)) --> \(srtTime(segment.endTime))\n"
            if let speaker = segment.speaker {
                srt += "[\(speaker)] "
            }
            srt += "\(segment.text)\n\n"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        panel.nameFieldStringValue = "\(meeting.title).srt"
        if panel.runModal() == .OK, let url = panel.url {
            try? srt.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func srtTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        let millis = Int((time.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 转录行视图

struct TranscriptLineView: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTap: () -> Void

    private var speakerColor: Color {
        if let speaker = segment.speaker {
            return Self.speakerTone(speaker)
        }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTime(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 40, alignment: .trailing)

            if let speaker = segment.speaker {
                let tone = Self.speakerTone(speaker)
                Text(speaker)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(tone.opacity(0.18))
                    )
                    .foregroundStyle(tone)
            }

            Text(segment.text)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineSpacing(5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? speakerColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // macOS 系统偏好设置风格亮色调色板
    private static let speakerPalette: [Color] = [
        Color(red: 0.35, green: 0.68, blue: 0.94),  // 蓝
        Color(red: 0.95, green: 0.55, blue: 0.30),  // 橙
        Color(red: 0.60, green: 0.82, blue: 0.40),  // 绿
        Color(red: 0.92, green: 0.42, blue: 0.50),  // 粉红
        Color(red: 0.70, green: 0.55, blue: 0.90),  // 紫
        Color(red: 0.90, green: 0.78, blue: 0.32),  // 黄
    ]

    static func speakerTone(_ speaker: String) -> Color {
        let sum = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return speakerPalette[sum % speakerPalette.count]
    }
}

// MARK: - 总结区块

struct SummarySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题级字号，不带图标，向系统设置分组标题的克制风格靠拢
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - 行内 Markdown 渲染工具

/// 解析行内 Markdown（**粗体** 等），失败时回退纯文本。
/// 文件内各处共享，保证待办、章节、问答的 Markdown 渲染行为一致。
private func renderInlineMarkdown(_ text: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        return Text(attributed)
    }
    return Text(text)
}

// MARK: - 总结 Markdown 渲染

private struct SummaryMarkdownView: View {
    let raw: String

    // 列表项：无序 / 有序，连续的列表项会归入同一个 list 块
    private enum ListItem {
        case bullet(text: String, indent: Int)        // 无序列表（indent 为缩进层级，从 0 起）
        case ordered(number: String, text: String)    // 有序列表（保留数字）
    }

    // 分组后的语义块
    private enum Block {
        case heading(text: String, level: Int)        // 标题（level 为 # 的个数）
        case paragraph(text: String)                  // 合并后的段落（行间用 \n 连接）
        case list(items: [ListItem])                  // 连续列表项归为一块
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 渲染单个语义块

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            renderInlineMarkdown(text)
                .font(.system(size: level <= 2 ? 15 : 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            renderInlineMarkdown(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    renderListItem(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func renderListItem(_ item: ListItem) -> some View {
        switch item {
        case .bullet(let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(indent == 0 ? "•" : "◦")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                renderInlineMarkdown(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .ordered(let number, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(number)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                renderInlineMarkdown(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 分组解析

    private func parse() -> [Block] {
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []   // 连续普通段落行缓冲
        var listBuffer: [ListItem] = []      // 连续列表项缓冲

        // 结束当前段落块：把缓冲的连续正文行用 \n 连接成一个段落
        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(text: paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer.removeAll()
        }
        // 结束当前列表块
        func flushList() {
            guard !listBuffer.isEmpty else { return }
            blocks.append(.list(items: listBuffer))
            listBuffer.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushList()
        }

        let lines = raw.components(separatedBy: .newlines)

        for rawLine in lines {
            // 空行：结束当前段落与列表块（不再单独生成 spacer，空白由 spacing 控制）
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                flushAll()
                continue
            }

            // 计算前导缩进（空格或 tab），用于判断列表层级
            let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // 标题：# / ## / ### …（结束在它前面积累的段落与列表）
            if let heading = matchHeading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            // 无序列表：- / * / +（段落到此结束，列表项连续累积）
            if let bulletText = matchBullet(trimmed) {
                flushParagraph()
                // 前导缩进 >= 2 视为二级及以下
                let indent = leadingSpaces >= 2 ? 1 : 0
                listBuffer.append(.bullet(text: bulletText, indent: indent))
                continue
            }

            // 有序列表：1. 2. …（段落到此结束，列表项连续累积）
            if let ordered = matchOrdered(trimmed) {
                flushParagraph()
                listBuffer.append(ordered)
                continue
            }

            // 普通段落行：先结束列表块，再累积进段落缓冲（合并连续正文）
            flushList()
            paragraphBuffer.append(trimmed)
        }

        // 文末收尾：清空剩余缓冲
        flushAll()
        return blocks
    }

    // 匹配标题，返回去掉 # 与空格后的正文
    private func matchHeading(_ line: String) -> Block? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(text: text, level: level)
    }

    // 匹配无序列表符号，返回去掉符号后的正文
    private func matchBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // 匹配有序列表（如 "1. 内容"），返回序号与正文
    private func matchOrdered(_ line: String) -> ListItem? {
        // 形如 数字 + "." + 空格
        guard let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) else {
            return nil
        }
        let number = String(line[line.startIndex..<line.index(before: range.upperBound)])
            .trimmingCharacters(in: .whitespaces)
        let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .ordered(number: number, text: text)
    }
}

// MARK: - 音频播放器

@MainActor
class MeetingAudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        // 获取时长
        Task {
            if let loadedDuration = try? await item.asset.load(.duration) {
                self.duration = CMTimeGetSeconds(loadedDuration)
            }
        }

        // 时间观察
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }

        // 播放结束通知
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
        }
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            // 开始播放前先暂停系统里正在播放的其他媒体（Music/Spotify 等），避免混在一起
            if MusicManager.shared.isPlaying {
                MusicManager.shared.pause()
            }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func stop() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
        isPlaying = false
    }
}

// MARK: - 滚轮/触控板事件检测（兼容 macOS 14+）

private struct ScrollWheelDetector: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> ScrollWheelInterceptView {
        ScrollWheelInterceptView(onScroll: onScroll)
    }

    func updateNSView(_ nsView: ScrollWheelInterceptView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollWheelInterceptView: NSView {
        var onScroll: () -> Void

        init(onScroll: @escaping () -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            if abs(event.scrollingDeltaY) > 0.5 || abs(event.scrollingDeltaX) > 0.5 {
                onScroll()
            }
        }
    }
}

extension View {
    func onScrollWheelOrTrackpad(perform action: @escaping () -> Void) -> some View {
        background(ScrollWheelDetector(onScroll: action))
    }
}
