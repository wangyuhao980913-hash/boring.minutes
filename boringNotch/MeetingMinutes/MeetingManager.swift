//
//  MeetingManager.swift
//  boringNotch
//
//  会议纪要核心管理器，协调录音、ASR、存储的生命周期
//

import AppKit
import AVFoundation
import Combine
import Defaults
import Foundation
import UserNotifications

@MainActor
class MeetingManager: ObservableObject {
    static let shared = MeetingManager()

    // MARK: - 状态

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0

    @Published var currentMeeting: MeetingRecord?
    @Published var meetingHistory: [MeetingRecord] = []

    @Published var audioLevel: Float = 0
    @Published var lastError: String?

    // MARK: - 云端同步状态

    enum CloudSyncStatus: Equatable {
        case idle
        case syncing
        case synced(count: Int)
        case failed(String)
    }

    @Published var cloudSyncStatus: CloudSyncStatus = .idle

    // MARK: - 服务

    let audioCaptureService = AudioCaptureService()

    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 临时文件路径

    private var tempDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cacheDir.appendingPathComponent("boringNotch/meeting_temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 本地存储目录（优先用户自定义路径，否则用 Documents）
    var localStorageDirectory: URL {
        let customPath = Defaults[.meetingLocalSavePath]
        if !customPath.isEmpty {
            let dir = URL(fileURLWithPath: customPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docDir.appendingPathComponent("BoringNotch/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        loadMeetingHistory()

        audioCaptureService.$audioLevel
            .receive(on: RunLoop.main)
            .assign(to: \.audioLevel, on: self)
            .store(in: &cancellables)

        // 启动时若已配置 TOS，先尝试迁移旧 index.json，再从云端拉取权威清单
        if TOSStorageService.shared.isConfigured {
            Task {
                await migrateFromLegacyIndexIfNeeded()
                await syncFromCloud()
            }
        }

        // TOS 密钥变更后（例如新设备刚填完）自动同步，实现"填完即可读回历史"
        Publishers.Merge4(
            Defaults.publisher(.tosAccessKeyId).map { _ in () },
            Defaults.publisher(.tosSecretAccessKey).map { _ in () },
            Defaults.publisher(.tosBucketName).map { _ in () },
            Defaults.publisher(.tosRegion).map { _ in () }
        )
        .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self = self, TOSStorageService.shared.isConfigured else { return }
            Task { await self.syncFromCloud() }
        }
        .store(in: &cancellables)
    }

    // MARK: - 旧 index.json 迁移

    /// 启动时一次性迁移：如果 TOS 上仍存在旧版 `meetings/index.json`，
    /// 将其中每条记录写为独立 `meetings/{uuid}/meta.json`，然后删除 index.json。
    /// 同时清理已废弃的墓碑 Defaults key。
    private func migrateFromLegacyIndexIfNeeded() async {
        do {
            let migrated = try await CloudIndexStore.shared.migrateFromLegacyIndex()
            if !migrated.isEmpty {
                NSLog("旧 index.json 迁移完成，共 \(migrated.count) 条会议")
            }
        } catch {
            NSLog("旧 index.json 迁移失败（非致命，下次启动再试）: \(error.localizedDescription)")
        }
        // 清理已废弃的墓碑 key
        Defaults[.deletedMeetingIDs] = []
    }

    // MARK: - 云端清单同步

    /// 把单条会议的元数据写入云端 `meetings/{uuid}/meta.json`。
    func pushMeetingToCloud(_ meeting: MeetingRecord) async {
        guard TOSStorageService.shared.isConfigured else { return }
        guard meetingHistory.contains(where: { $0.id == meeting.id }) else { return }
        do {
            try await CloudIndexStore.shared.writeMeta(meeting)
        } catch {
            NSLog("会议 meta.json 写入失败: \(error.localizedDescription)")
        }
    }

    /// 删除云端 `meetings/{uuid}/` 整个目录（meta + audio + transcript + summary）。
    func removeMeetingFromCloud(id: UUID) async {
        guard TOSStorageService.shared.isConfigured else { return }
        do {
            try await CloudIndexStore.shared.removeMeeting(uuid: id)
            NSLog("[MeetingManager] removeMeetingFromCloud 成功: %@", id.uuidString)
        } catch {
            NSLog("[MeetingManager] removeMeetingFromCloud 失败: uuid=%@ error=%@", id.uuidString, error.localizedDescription)
        }
    }

    /// 通过 ListObjectsV2 发现所有会议目录，以云端为权威覆盖本地。
    func syncFromCloud() async {
        guard TOSStorageService.shared.isConfigured else { return }
        cloudSyncStatus = .syncing
        do {
            let cloudRecords = try await CloudIndexStore.shared.listAllMeetings()
            let merged = cloudRecords.sorted { $0.startDate > $1.startDate }
            meetingHistory = merged
            saveMeetingHistory()
            cloudSyncStatus = .synced(count: merged.count)
        } catch {
            cloudSyncStatus = .failed(error.localizedDescription)
            NSLog("云端同步失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 开始录制

    func startRecording() async {
        guard !isRecording else { return }

        // 先请求麦克风权限：未决定时会弹出苹果标准系统弹窗；被拒则用系统 NSAlert 引导去设置
        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            presentPermissionAlert(
                title: "需要「麦克风」权限",
                message: "boringNotch 需要访问麦克风才能录制会议。请在 系统设置 → 隐私与安全性 → 麦克风 中打开 boringNotch。",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
            return
        }

        let meeting = MeetingRecord(
            title: generateDefaultTitle(),
            startDate: Date(),
            status: .recording
        )
        currentMeeting = meeting

        // 录制阶段先写无损 WAV（不经过编码器，物理上不会失败），停止后再一次性转 m4a
        let audioFileName = "\(meeting.dateBasedPath).wav"
        let audioURL = tempDirectory.appendingPathComponent(audioFileName)
        currentMeeting?.localAudioPath = audioURL.path

        lastError = nil

        do {
            try await audioCaptureService.startCapture(outputURL: audioURL)
            isRecording = true
            recordingStartDate = Date()
            startDurationTimer()
        } catch let error as AudioCaptureError where error == .screenRecordingDenied {
            // 屏幕录制权限缺失
            DebugSessionLog.write(hypothesisId: "D", location: "MeetingManager.startRecording", message: "start_failed_permission", data: ["error": error.localizedDescription])
            currentMeeting = nil

            if Defaults[.hasRequestedScreenRecording] {
                // 之前已请求过、现在仍无权限：说明用户没在设置里勾选，用系统 NSAlert 引导去设置
                presentPermissionAlert(
                    title: "需要「屏幕录制」权限",
                    message: "boringNotch 需要「屏幕录制」权限来采集系统声音。请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 boringNotch，然后完全退出并重启应用后再录音（首次授权后必须重启才会生效）。",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            } else {
                // 首次请求：CGRequestScreenCaptureAccess 已弹出系统标准窗（首次总是返回 false），
                // 只记录标记、不再叠加第二个自定义弹窗。
                Defaults[.hasRequestedScreenRecording] = true
            }
        } catch {
            NSLog("开始录制失败: \(error.localizedDescription)")
            lastError = "录制失败: \(error.localizedDescription)"
            DebugSessionLog.write(hypothesisId: "D", location: "MeetingManager.startRecording", message: "start_failed", data: ["error": error.localizedDescription])
            currentMeeting = nil
        }
    }

    // MARK: - 权限

    /// 请求麦克风权限。未决定时触发系统标准弹窗；已授权直接返回 true；已拒绝返回 false。
    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// 权限缺失时弹出系统标准 NSAlert，提供「打开系统设置」直达对应隐私页。
    private func presentPermissionAlert(title: String, message: String, settingsURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 停止录制

    func stopRecording() async {
        guard isRecording else { return }

        stopDurationTimer()

        await audioCaptureService.stopCapture()

        isRecording = false

        guard var meeting = currentMeeting else { return }
        meeting.duration = recordingDuration
        meeting.status = .processing

        // 录完把 WAV 一次性转成 m4a（体积小、可播），失败则回退用 WAV
        if let wavPath = meeting.localAudioPath {
            let wavURL = URL(fileURLWithPath: wavPath)
            let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try await AudioCaptureService.exportToM4A(source: wavURL, destination: m4aURL)
                try? FileManager.default.removeItem(at: wavURL)
                meeting.localAudioPath = m4aURL.path
                DebugSessionLog.write(hypothesisId: "X", location: "MeetingManager.stopRecording", message: "export_m4a_ok", data: ["path": m4aURL.path])
            } catch {
                NSLog("WAV 转 m4a 失败，保留 WAV: \(error.localizedDescription)")
                DebugSessionLog.write(hypothesisId: "X", location: "MeetingManager.stopRecording", message: "export_m4a_failed", data: ["error": error.localizedDescription])
            }
        }

        currentMeeting = meeting

        // 询问用户是否要生成会议总结（默认"总结会议"）
        let wantsSummary = askWhetherToSummarize()

        // 未总结时先标记为黄灯状态入库；总结时保持 processing
        meeting.status = wantsSummary ? .processing : .notSummarized
        currentMeeting = meeting

        // 保存到历史
        addToHistory(meeting)

        // 后台处理：上传 TOS +（可选）提交妙记
        Task {
            await processCompletedMeeting(meeting, summarize: wantsSummary)
        }

        recordingDuration = 0
        recordingStartDate = nil
    }

    /// 停止录制后弹系统标准弹窗询问是否总结；默认按钮为"总结会议"。
    private func askWhetherToSummarize() -> Bool {
        let alert = NSAlert()
        alert.messageText = "是否总结这次会议？"
        alert.informativeText = "总结会议会上传录音并调用妙记生成文字记录、章节与待办。若这次录音没什么价值，可以选择暂不总结，之后随时可以在回看里补总结。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "总结会议")   // 默认按钮（更明显）
        alert.addButton(withTitle: "暂不总结")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 会后处理

    private func processCompletedMeeting(_ meeting: MeetingRecord, summarize: Bool) async {
        var updatedMeeting = meeting
        let tos = TOSStorageService.shared
        let miaoji = DoubaoMiaojiService.shared
        // 是否要跑妙记总结：由用户在停止录制时的选择决定
        let wantsAutoSummary = summarize
        var miaojiSucceeded = false

        // 录音文件实际扩展名（正常录制为 m4a，导入测试可能是 mp3/wav）
        let fileExt: String = {
            let e = (meeting.localAudioPath as NSString?)?.pathExtension ?? ""
            return e.isEmpty ? "m4a" : e.lowercased()
        }()

        // 1. 上传录音到 TOS（如果配置了）
        if tos.isConfigured, let localPath = meeting.localAudioPath {
            let sourceURL = URL(fileURLWithPath: localPath)
            let objectKey = "\(meeting.tosPrefix)audio.\(fileExt)"

            do {
                let key = try await tos.uploadFile(localURL: sourceURL, objectKey: objectKey)
                updatedMeeting.audioObjectKey = key
                updateMeetingInHistory(updatedMeeting)

                // 2. 提交豆包语音妙记（需要 TOS 公网 URL + 妙记凭证）
                if wantsAutoSummary {
                    if miaoji.isConfigured {
                        // 妙记要求预签名 URL 至少 24 小时有效
                        if let presignedURL = tos.presignedURL(objectKey: objectKey, expiration: 86_400) {
                            do {
                                if let result = try await miaoji.submitAndWait(
                                    audioURL: presignedURL.absoluteString,
                                    language: "zh-CN"
                                ) {
                                    // 妙记转写结果（文件版更准、带说话人）
                                    if !result.segments.isEmpty {
                                        updatedMeeting.segments = result.segments
                                        let transcriptKey = "\(meeting.tosPrefix)transcript.json"
                                        let transcriptData = try JSONEncoder().encode(updatedMeeting.segments)
                                        _ = try await tos.uploadData(transcriptData, objectKey: transcriptKey, contentType: "application/json")
                                        updatedMeeting.transcriptObjectKey = transcriptKey
                                    }
                                    updatedMeeting.summary = result.summary

                                    if let suggestedTitle = result.suggestedTitle,
                                       !suggestedTitle.isEmpty,
                                       meeting.title == generateDefaultTitleForDate(meeting.startDate)
                                    {
                                        updatedMeeting.title = suggestedTitle
                                    }

                                    if let summary = updatedMeeting.summary {
                                        let summaryKey = "\(meeting.tosPrefix)summary.json"
                                        let summaryData = try JSONEncoder().encode(summary)
                                        _ = try await tos.uploadData(summaryData, objectKey: summaryKey, contentType: "application/json")
                                        updatedMeeting.summaryObjectKey = summaryKey
                                    }

                                    miaojiSucceeded = true
                                }
                            } catch {
                                NSLog("妙记 API 处理失败: \(error.localizedDescription)")
                                DebugSessionLog.write(hypothesisId: "M", location: "MeetingManager.processCompletedMeeting", message: "miaoji_failed", data: ["error": error.localizedDescription])
                            }
                        } else {
                            NSLog("妙记跳过: 无法生成 TOS 预签名 URL")
                        }
                    } else {
                        NSLog("妙记跳过: 未配置 App ID 或 Access Token")
                    }
                }

                // 妙记成功或未启用自动总结时，删除本地临时文件
                if miaojiSucceeded || !wantsAutoSummary {
                    try? FileManager.default.removeItem(at: sourceURL)
                    updatedMeeting.localAudioPath = nil
                } else {
                    // 妙记失败时保留本地录音
                    let destURL = localStorageDirectory.appendingPathComponent("\(meeting.dateBasedPath).\(fileExt)")
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try? FileManager.default.removeItem(at: destURL)
                    }
                    try? FileManager.default.moveItem(at: sourceURL, to: destURL)
                    updatedMeeting.localAudioPath = destURL.path
                }

            } catch {
                NSLog("TOS 上传失败，回退到本地存储: \(error.localizedDescription)")
                DebugSessionLog.write(hypothesisId: "U", location: "MeetingManager.processCompletedMeeting", message: "tos_upload_failed", data: ["error": error.localizedDescription])
                let destURL = localStorageDirectory.appendingPathComponent("\(meeting.dateBasedPath).\(fileExt)")
                try? FileManager.default.moveItem(at: sourceURL, to: destURL)
                updatedMeeting.localAudioPath = destURL.path
            }
        } else {
            if wantsAutoSummary {
                NSLog("妙记跳过: 会后纪要需要配置 TOS 云存储（妙记需要公网音频 URL）")
            }
            if let localPath = meeting.localAudioPath {
                let sourceURL = URL(fileURLWithPath: localPath)
                let destURL = localStorageDirectory.appendingPathComponent("\(meeting.dateBasedPath).\(fileExt)")
                try? FileManager.default.moveItem(at: sourceURL, to: destURL)
                updatedMeeting.localAudioPath = destURL.path
            }
        }

        // 最终状态：总结成功→完成；用户没要总结→未总结（黄灯）；要总结但没跑成→失败（可重试补总结）
        if miaojiSucceeded {
            updatedMeeting.status = .completed
        } else if summarize {
            updatedMeeting.status = .failed
        } else {
            updatedMeeting.status = .notSummarized
        }
        updateMeetingInHistory(updatedMeeting)

        // 同步更新 currentMeeting，确保 UI 引用的路径是最新的
        if currentMeeting?.id == updatedMeeting.id {
            currentMeeting = updatedMeeting
        }

        // 写入云端权威清单（换设备可读回）
        await pushMeetingToCloud(updatedMeeting)

        if updatedMeeting.status == .completed {
            sendCompletionNotification(for: updatedMeeting)
        }
    }

    // MARK: - 补总结（对"暂不总结"或"失败"的会议后续生成总结）

    /// 对已存在的会议补跑妙记总结。优先用云端音频（audioObjectKey）生成预签名 URL，
    /// 否则回退用本地音频先上传再总结。
    func summarizeMeeting(_ meeting: MeetingRecord) async {
        guard meeting.status != .processing else { return }
        let tos = TOSStorageService.shared
        let miaoji = DoubaoMiaojiService.shared

        guard tos.isConfigured else {
            presentInfoAlert(title: "无法总结", message: "会后总结需要先在设置里配置 TOS 云存储与妙记凭证（妙记需要公网音频 URL）。")
            return
        }
        guard miaoji.isConfigured else {
            presentInfoAlert(title: "无法总结", message: "请先在设置里填写妙记 App ID 与 Access Token。")
            return
        }

        // 置为处理中
        var updated = meeting
        updated.status = .processing
        updateMeetingInHistory(updated)
        if currentMeeting?.id == updated.id { currentMeeting = updated }

        // 确定音频对象键：云端已有直接用；否则用本地音频上传
        var objectKey = meeting.audioObjectKey
        if objectKey == nil, let localPath = meeting.localAudioPath,
           FileManager.default.fileExists(atPath: localPath)
        {
            let ext = (localPath as NSString).pathExtension.isEmpty ? "m4a" : (localPath as NSString).pathExtension.lowercased()
            let key = "\(meeting.tosPrefix)audio.\(ext)"
            do {
                objectKey = try await tos.uploadFile(localURL: URL(fileURLWithPath: localPath), objectKey: key)
                updated.audioObjectKey = objectKey
                updateMeetingInHistory(updated)
            } catch {
                NSLog("补总结上传音频失败: \(error.localizedDescription)")
            }
        }

        guard let key = objectKey,
              let presignedURL = tos.presignedURL(objectKey: key, expiration: 86_400)
        else {
            updated.status = .failed
            updateMeetingInHistory(updated)
            if currentMeeting?.id == updated.id { currentMeeting = updated }
            presentInfoAlert(title: "无法总结", message: "找不到可用的录音文件，无法提交妙记。")
            return
        }

        do {
            if let result = try await miaoji.submitAndWait(audioURL: presignedURL.absoluteString, language: "zh-CN") {
                if !result.segments.isEmpty {
                    updated.segments = result.segments
                    let transcriptKey = "\(meeting.tosPrefix)transcript.json"
                    if let data = try? JSONEncoder().encode(updated.segments) {
                        _ = try? await tos.uploadData(data, objectKey: transcriptKey, contentType: "application/json")
                        updated.transcriptObjectKey = transcriptKey
                    }
                }
                updated.summary = result.summary
                if let suggestedTitle = result.suggestedTitle, !suggestedTitle.isEmpty,
                   meeting.title == generateDefaultTitleForDate(meeting.startDate)
                {
                    updated.title = suggestedTitle
                }
                if let summary = updated.summary {
                    let summaryKey = "\(meeting.tosPrefix)summary.json"
                    if let data = try? JSONEncoder().encode(summary) {
                        _ = try? await tos.uploadData(data, objectKey: summaryKey, contentType: "application/json")
                        updated.summaryObjectKey = summaryKey
                    }
                }
                updated.status = .completed
            } else {
                updated.status = .failed
            }
        } catch {
            NSLog("补总结妙记失败: \(error.localizedDescription)")
            updated.status = .failed
        }

        updateMeetingInHistory(updated)
        if currentMeeting?.id == updated.id { currentMeeting = updated }
        await pushMeetingToCloud(updated)
        if updated.status == .completed { sendCompletionNotification(for: updated) }
    }

    // MARK: - 导入音频测试

    /// 选一个本地音频文件当作一次会议处理：拷贝到临时目录后走完整的上传 + 妙记总结流程，
    /// 便于在不实际录音的情况下验证 TOS 上传与妙记返回（章节 / 待办 / 问答等）。
    func importAudioForTesting(url: URL) async {
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        var meeting = MeetingRecord(
            title: url.deletingPathExtension().lastPathComponent,
            startDate: Date(),
            status: .processing
        )

        // 拷贝到临时目录，绝不直接操作用户原文件（处理流程成功后会删除这个临时副本）
        let destURL = tempDirectory.appendingPathComponent("\(meeting.dateBasedPath).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            NSLog("导入测试拷贝音频失败: \(error.localizedDescription)")
            lastError = "导入失败: \(error.localizedDescription)"
            return
        }
        meeting.localAudioPath = destURL.path

        // 读取真实时长用于展示
        if let duration = try? await AVURLAsset(url: destURL).load(.duration) {
            meeting.duration = CMTimeGetSeconds(duration)
        }

        let wantsSummary = askWhetherToSummarize()
        meeting.status = wantsSummary ? .processing : .notSummarized

        addToHistory(meeting)
        await processCompletedMeeting(meeting, summarize: wantsSummary)
    }

    /// 通用信息提示弹窗。
    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 系统通知

    private func sendCompletionNotification(for meeting: MeetingRecord) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "会议纪要已就绪"
        content.body = "\(meeting.title) (\(meeting.formattedDuration))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: meeting.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    // MARK: - 计时器

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let startDate = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - 历史记录管理

    private func loadMeetingHistory() {
        let historyURL = localStorageDirectory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: historyURL),
              let records = try? JSONDecoder().decode([MeetingRecord].self, from: data)
        else { return }
        meetingHistory = records.sorted { $0.startDate > $1.startDate }
    }

    private func saveMeetingHistory() {
        let historyURL = localStorageDirectory.appendingPathComponent("history.json")
        guard let data = try? JSONEncoder().encode(meetingHistory) else { return }
        try? data.write(to: historyURL)
    }

    private func addToHistory(_ meeting: MeetingRecord) {
        meetingHistory.insert(meeting, at: 0)
        saveMeetingHistory()
    }

    private func updateMeetingInHistory(_ meeting: MeetingRecord) {
        if let index = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
            meetingHistory[index] = meeting
            saveMeetingHistory()
        }
    }

    func renameMeeting(_ meeting: MeetingRecord, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
            meetingHistory[index].title = trimmed
            saveMeetingHistory()
            // 重命名同步到云端清单
            let updated = meetingHistory[index]
            Task { await pushMeetingToCloud(updated) }
        }

        if currentMeeting?.id == meeting.id {
            currentMeeting?.title = trimmed
        }
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        if let localPath = meeting.localAudioPath {
            try? FileManager.default.removeItem(atPath: localPath)
        }

        if TOSStorageService.shared.isConfigured {
            let meetingId = meeting.id
            let legacyKeys = [meeting.audioObjectKey, meeting.transcriptObjectKey, meeting.summaryObjectKey].compactMap { $0 }
            Task {
                NSLog("[MeetingManager] 开始删除云端会议: %@ (prefix=meetings/%@/)", meeting.title, meetingId.uuidString)
                do {
                    await self.removeMeetingFromCloud(id: meetingId)
                    for key in legacyKeys where !key.hasPrefix("meetings/\(meetingId.uuidString)/") {
                        do {
                            try await TOSStorageService.shared.deleteObject(objectKey: key)
                        } catch {
                            NSLog("[MeetingManager] 旧路径对象删除失败: key=\"%@\" error=%@", key, error.localizedDescription)
                        }
                    }
                    NSLog("[MeetingManager] 云端会议删除完成: %@", meetingId.uuidString)
                }
            }
        }

        meetingHistory.removeAll { $0.id == meeting.id }
        saveMeetingHistory()
    }

    func openReviewWindow(for meeting: MeetingRecord) {
        MeetingReviewWindowController.shared.showWindow(for: meeting)
    }

    // MARK: - 工具方法

    private func generateDefaultTitle() -> String {
        generateDefaultTitleForDate(Date())
    }

    private func generateDefaultTitleForDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm 会议"
        return formatter.string(from: date)
    }

    var formattedRecordingDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 云端 per-meeting 存取

/// 每条会议独立目录 `meetings/{uuid}/`，元数据存 `meta.json`。
/// 不再依赖全局 index.json，并发安全、删除即生效。
actor CloudIndexStore {
    static let shared = CloudIndexStore()

    private let tos = TOSStorageService.shared

    /// 写入或更新单条会议的 meta.json。
    func writeMeta(_ meeting: MeetingRecord) async throws {
        let meta = MetaRecord(from: meeting)
        let data = try JSONEncoder().encode(meta)
        let key = "\(meeting.tosPrefix)meta.json"
        _ = try await tos.uploadData(data, objectKey: key, contentType: "application/json")
    }

    /// 读取单条会议的 meta.json。
    func readMeta(uuid: UUID) async throws -> MetaRecord? {
        let key = "meetings/\(uuid.uuidString)/meta.json"
        guard let data = try await tos.downloadData(objectKey: key) else { return nil }
        return try? JSONDecoder().decode(MetaRecord.self, from: data)
    }

    /// 删除整个 `meetings/{uuid}/` 目录（meta + audio + transcript + summary）。
    func removeMeeting(uuid: UUID) async throws {
        let prefix = "meetings/\(uuid.uuidString)/"
        try await tos.deleteAllObjects(withPrefix: prefix)
    }

    /// 通过 ListObjectsV2 发现所有会议目录，逐个读取 meta.json，返回全量元数据。
    func listAllMeetings() async throws -> [MeetingRecord] {
        let prefixes = try await tos.listCommonPrefixes(prefix: "meetings/", delimiter: "/")

        var records: [MeetingRecord] = []
        for prefix in prefixes {
            let components = prefix.split(separator: "/")
            guard components.count >= 2,
                  let uuid = UUID(uuidString: String(components[1]))
            else { continue }

            if let meta = try? await readMeta(uuid: uuid) {
                var record = meta.toMeetingRecord()
                if let tKey = record.transcriptObjectKey,
                   let tData = try? await tos.downloadData(objectKey: tKey) {
                    record.segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: tData)) ?? []
                }
                if let sKey = record.summaryObjectKey,
                   let sData = try? await tos.downloadData(objectKey: sKey) {
                    record.summary = try? JSONDecoder().decode(MeetingSummary.self, from: sData)
                }
                records.append(record)
            }
        }
        return records
    }

    // MARK: - 旧 index.json 迁移

    /// 读取旧版全局 index.json（迁移用），成功后删除该文件。
    func migrateFromLegacyIndex() async throws -> [MeetingRecord] {
        let legacyKey = "meetings/index.json"
        guard let data = try await tos.downloadData(objectKey: legacyKey) else { return [] }
        let records = (try? JSONDecoder().decode([MeetingRecord].self, from: data)) ?? []

        for record in records {
            try? await writeMeta(record)
        }

        try? await tos.deleteObject(objectKey: legacyKey)
        return records
    }
}
