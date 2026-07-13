//
//  MeetingSettingsView.swift
//  boringNotch
//
//  会议纪要设置页：总开关、本地保存、自动总结（含妙记/TOS 凭证与验证）。
//

import AppKit
import Defaults
import SwiftUI

struct MeetingSettings: View {
    @Default(.enableMeeting) private var enableMeeting
    @Default(.meetingAutoSummary) private var autoSummary
    @Default(.meetingLocalSavePath) private var localSavePath

    @Default(.miaojiAppId) private var miaojiAppId
    @Default(.miaojiAccessToken) private var miaojiAccessToken
    @Default(.tosAccessKeyId) private var tosAccessKeyId
    @Default(.tosSecretAccessKey) private var tosSecretAccessKey
    @Default(.tosBucketName) private var tosBucketName
    @Default(.tosRegion) private var tosRegion

    @ObservedObject private var meetingManager = MeetingManager.shared

    @State private var isValidating = false
    @State private var validationOK: Bool?
    @State private var validationMessage: String = ""

    // 妙记与 TOS 是否都已填写
    private var credentialsFilled: Bool {
        !miaojiAppId.isEmpty && !miaojiAccessToken.isEmpty
            && !tosAccessKeyId.isEmpty && !tosSecretAccessKey.isEmpty && !tosBucketName.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableMeeting) {
                    Text("开启会议纪要")
                }
                Text("开启后，刘海会出现「会议」标签，可录制会议音频并在会后生成纪要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("通用")) {
                HStack {
                    TextField("本地保存路径（留空用默认）", text: $localSavePath)
                    Button("选择…") { chooseFolder() }
                }
            }

            Section(header: Text("会后总结")) {
                Defaults.Toggle(key: .meetingAutoSummary) {
                    Text("会议结束后自动生成总结")
                }

                if autoSummary {
                    // 未填凭证时的醒目告知
                    if !credentialsFilled {
                        Label(
                            "未填写妙记 / TOS 凭证，会议结束后不会自动生成总结，仅在本地保存录音。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    // 凭证子项（比开关低一级）
                    Group {
                        credentialField(title: "妙记 App ID", text: $miaojiAppId, secure: false)
                        credentialField(title: "妙记 Access Token", text: $miaojiAccessToken, secure: true)
                        credentialField(title: "TOS Access Key ID", text: $tosAccessKeyId, secure: false)
                        credentialField(title: "TOS Secret Access Key", text: $tosSecretAccessKey, secure: true)
                        credentialField(title: "TOS Bucket", text: $tosBucketName, secure: false)
                        credentialField(title: "TOS Region（例：cn-shanghai）", text: $tosRegion, secure: false)

                        Text("妙记需要公网可访问的音频 URL，因此会后总结依赖 TOS。仅本地录音可不填。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("历史记录会以 TOS 为准：换设备装好后填入相同 TOS 密钥即可自动读回全部历史。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        cloudSyncStatusView

                        // 验证连接
                        HStack(spacing: 8) {
                            Button {
                                validate()
                            } label: {
                                if isValidating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("验证连接")
                                }
                            }
                            .disabled(isValidating || !credentialsFilled)

                            if let ok = validationOK, !isValidating {
                                Label(
                                    validationMessage,
                                    systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(ok ? .green : .red)
                            }
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .navigationTitle("Meeting")
    }

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        switch meetingManager.cloudSyncStatus {
        case .idle:
            EmptyView()
        case .syncing:
            Label("正在从云端同步历史…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .synced(let count):
            Label("云端同步完成：共 \(count) 条会议", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Label("云端同步失败：\(msg)", systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func credentialField(title: String, text: Binding<String>, secure: Bool) -> some View {
        if secure {
            SecureField(title, text: text)
        } else {
            TextField(title, text: text)
        }
    }

    private func validate() {
        isValidating = true
        validationOK = nil
        validationMessage = ""
        Task {
            async let tos = TOSStorageService.shared.validateCredentials()
            async let miaoji = DoubaoMiaojiService.shared.validateCredentials()
            let (tosOK, tosMsg) = await tos
            let (miaojiOK, miaojiMsg) = await miaoji
            await MainActor.run {
                validationOK = tosOK && miaojiOK
                validationMessage = "妙记：\(miaojiMsg)；TOS：\(tosMsg)"
                isValidating = false
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            localSavePath = url.path
        }
    }
}
