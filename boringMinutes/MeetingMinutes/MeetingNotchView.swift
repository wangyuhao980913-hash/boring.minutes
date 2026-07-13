//
//  MeetingNotchView.swift
//  boringNotch
//
//  刘海内的会议纪要紧凑面板：录音控制、滚动声波、状态、最近会议、导入测试。
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct MeetingNotchView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @EnvironmentObject var vm: BoringViewModel

    // 是否悬停在会议列表上
    @State private var hoveringList = false
    // 正在进行的模态交互计数（重命名弹窗、文件导入）；>0 时视为交互中
    @State private var activeInteractions = 0
    // 待删除的会议：删除确认对话框挂在父级，行被删除销毁也不会丢失状态
    @State private var pendingDelete: MeetingRecord?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            controlColumn
                .frame(width: 150)

            Divider()
                .overlay(Color.white.opacity(0.12))

            rightColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: hoveringList) { _, _ in updateSuppress() }
        .onChange(of: activeInteractions) { _, _ in updateSuppress() }
        .onChange(of: pendingDelete?.id) { _, _ in updateSuppress() }
        .onDisappear { vm.suppressAutoClose = false }
        // 删除确认挂在父级：确认删除后行视图即使销毁，状态也随对话框关闭正常复位
        .confirmationDialog(
            "确定删除这条录音吗？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let meeting = pendingDelete {
                    manager.deleteMeeting(meeting)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
    }

    // 悬停列表、存在模态交互或删除确认弹出时，抑制刘海自动收回
    private func updateSuppress() {
        vm.suppressAutoClose = hoveringList || activeInteractions > 0 || pendingDelete != nil
    }

    // 弹系统文件选择器，选一个音频文件走完整的上传 + 妙记总结流程
    private func importAudioForTest() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await manager.importAudioForTesting(url: url) }
        }
    }

    // MARK: - 左侧：录音控制

    private var controlColumn: some View {
        VStack(spacing: 8) {
            Text(manager.isRecording ? manager.formattedRecordingDuration : "00:00")
                .font(.system(size: 24, weight: .thin, design: .monospaced))
                .foregroundStyle(manager.isRecording ? .white : .gray)

            Button {
                Task {
                    if manager.isRecording {
                        await manager.stopRecording()
                    } else {
                        await manager.startRecording()
                    }
                }
            } label: {
                Image(systemName: manager.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 40))
                    // 未录制时低调灰，录制时清晰红
                    .foregroundStyle(manager.isRecording ? .red : Color.gray.opacity(0.6))
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: manager.isRecording)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - 右侧：波形 + 状态 + 最近会议

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            MeetingLevelMeter(level: manager.audioLevel, active: manager.isRecording)
                .frame(height: 30)

            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if manager.isRecording {
                Label("录制中…", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("最近会议")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.gray)
                Spacer()
                Button {
                    importAudioForTest()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("导入音频")
            }

            if manager.meetingHistory.isEmpty {
                Text("暂无记录")
                    .font(.caption2)
                    .foregroundStyle(.gray.opacity(0.7))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(manager.meetingHistory.prefix(6)) { meeting in
                            MeetingRowView(
                                meeting: meeting,
                                manager: manager,
                                activeInteractions: $activeInteractions,
                                onDelete: { pendingDelete = meeting }
                            )
                        }
                    }
                    // 右侧留白，给滚动条让位，避免与行内垃圾桶图标重叠
                    .padding(.trailing, 12)
                }
                // 悬停/滚动会议列表期间，抑制刘海自动收回
                .onHover { hovering in
                    hoveringList = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// MARK: - 单条会议行（标题打开回看 + 重命名 + 删除）

private struct MeetingRowView: View {
    let meeting: MeetingRecord
    @ObservedObject var manager: MeetingManager
    @Binding var activeInteractions: Int
    // 删除请求交给父级弹确认框，避免行销毁后交互计数失衡
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isHovering = false
    @State private var trashHover = false

    var body: some View {
        HStack(spacing: 6) {
            statusDot(meeting.status)

            // 标题：点击打开回看窗口
            Button {
                manager.openReviewWindow(for: meeting)
            } label: {
                Text(meeting.title)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 右侧：默认显示日期+时长；hover 时信息带呼吸感左移、露出垃圾桶
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Text(meeting.formattedDate)
                    Text(meeting.formattedDuration)
                }
                .font(.caption2)
                .foregroundStyle(.gray)
                .fixedSize()
                // hover 时整块信息左移让出垃圾桶位；垃圾桶本身也整体左移一格避开滚动条
                .offset(x: isHovering ? -40 : 0)

                if isHovering {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(trashHover ? .red : .gray)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                    .onHover { trashHover = $0 }
                    .transition(.opacity)
                    // 垃圾桶不贴右边缘，向左错开一个图标位，与滚动条彻底分离
                    .offset(x: -18)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // 右侧额外留白，避开滚动条（hover 放大态下也不重叠）
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.gray.opacity(0.16) : Color.clear)
        )
        // 以左边缘为锚点放大，避免 hover 时左侧状态点与标题向左溢出画框
        .scaleEffect(isHovering ? 1.03 : 1.0, anchor: .leading)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if !hovering { trashHover = false }
        }
        // 右键菜单：重命名 / 删除
        .contextMenu {
            Button {
                draftTitle = meeting.title
                isRenaming = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // 重命名弹窗（由右键菜单触发）
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("重命名会议")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("会议名称", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(commitRename)
                HStack {
                    Spacer()
                    Button("取消") { isRenaming = false }
                    Button("保存", action: commitRename)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        // 重命名弹窗打开时计入交互，防止刘海收回
        .onChange(of: isRenaming) { _, active in
            activeInteractions += active ? 1 : -1
            activeInteractions = max(0, activeInteractions)
        }
        // 兜底：行视图销毁时若重命名弹窗仍开着，归还占用的计数，防止刘海永久卡住
        .onDisappear {
            if isRenaming {
                activeInteractions = max(0, activeInteractions - 1)
            }
        }
    }

    private func commitRename() {
        manager.renameMeeting(meeting, newTitle: draftTitle)
        isRenaming = false
    }

    @ViewBuilder
    private func statusDot(_ status: MeetingStatus) -> some View {
        let color: Color = {
            switch status {
            case .recording: return .red
            case .processing: return .orange
            case .notSummarized: return .yellow
            case .completed: return .green
            case .failed: return .red
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - 滚动声波（新值从右侧进入）

private struct MeetingLevelMeter: View {
    let level: Float
    let active: Bool

    private static let barCount = 40
    @State private var history: [Float] = Array(repeating: 0, count: MeetingLevelMeter.barCount)

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = (geo.size.width - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    let amplitude = history[i]
                    let h = max(2, CGFloat(amplitude) * geo.size.height)
                    RoundedRectangle(cornerRadius: max(1, barWidth / 2))
                        // 未录制时浅灰、低调；录制时较明显的灰
                        .fill(active ? Color.gray.opacity(0.85) : Color.gray.opacity(0.22))
                        .frame(width: max(1, barWidth), height: h)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .onChange(of: level) { _, newValue in
            pushLevel(newValue)
        }
        .onChange(of: active) { _, isActive in
            if !isActive {
                withAnimation(.easeOut(duration: 0.25)) {
                    history = Array(repeating: 0, count: Self.barCount)
                }
            }
        }
    }

    private func pushLevel(_ raw: Float) {
        let shaped = min(1.0, sqrtf(max(0, raw)) * 2.2)
        var next = history
        next.removeFirst()
        next.append(shaped)
        withAnimation(.easeOut(duration: 0.08)) {
            history = next
        }
    }
}
