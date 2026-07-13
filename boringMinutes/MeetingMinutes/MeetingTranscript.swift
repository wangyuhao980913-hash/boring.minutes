//
//  MeetingTranscript.swift
//  boringNotch
//
//  会议纪要数据模型
//

import Foundation
import Defaults

// MARK: - 转录片段（一句话）

struct TranscriptSegment: Codable, Identifiable, Hashable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var isFinal: Bool

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        speaker: String? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.isFinal = isFinal
    }
}

// MARK: - 会议总结（妙记 API 返回的结构化数据）

struct MeetingSummary: Codable {
    var fullSummary: String?
    var chapters: [ChapterSummary]?
    var todoItems: [TodoItem]?
    var qaItems: [QAItem]?

    struct ChapterSummary: Codable, Identifiable {
        let id: UUID
        var title: String
        var summary: String
        var startTime: TimeInterval
        var endTime: TimeInterval

        init(id: UUID = UUID(), title: String, summary: String, startTime: TimeInterval, endTime: TimeInterval) {
            self.id = id
            self.title = title
            self.summary = summary
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    struct TodoItem: Codable, Identifiable {
        let id: UUID
        var assignee: String?
        var content: String
        var deadline: String?

        init(id: UUID = UUID(), assignee: String? = nil, content: String, deadline: String? = nil) {
            self.id = id
            self.assignee = assignee
            self.content = content
            self.deadline = deadline
        }
    }

    struct QAItem: Codable, Identifiable {
        let id: UUID
        var question: String
        var answer: String

        init(id: UUID = UUID(), question: String, answer: String) {
            self.id = id
            self.question = question
            self.answer = answer
        }
    }
}

// MARK: - 会议记录（一次完整的会议）

struct MeetingRecord: Codable, Identifiable {
    let id: UUID
    var title: String
    var startDate: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?

    // TOS 云存储路径
    var audioObjectKey: String?
    var transcriptObjectKey: String?
    var summaryObjectKey: String?

    // 本地临时文件路径（录制中使用，上传后清除）
    var localAudioPath: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        startDate: Date = Date(),
        duration: TimeInterval = 0,
        status: MeetingStatus = .recording,
        segments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.duration = duration
        self.status = status
        self.segments = segments
        self.summary = summary
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: startDate)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var dateBasedPath: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: startDate)
    }

    /// 云端目录前缀。设置了用户名时为 `{user}/meetings/{uuid}/`，否则为 `meetings/{uuid}/`。
    var tosPrefix: String {
        let user = Defaults[.tosUserPrefix].trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            return "meetings/\(id.uuidString)/"
        }
        return "\(user)/meetings/\(id.uuidString)/"
    }
}

// MARK: - 会议状态

enum MeetingStatus: String, Codable {
    case recording
    case processing
    case notSummarized
    case completed
    case failed
}

// MARK: - 轻量元数据（per-meeting meta.json）

/// 存储在 TOS `meetings/{uuid}/meta.json` 的轻量记录。
/// 不含 segments 和 summary 正文（它们各有独立文件），只存指针和状态。
struct MetaRecord: Codable {
    let id: UUID
    var title: String
    var startDate: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var audioObjectKey: String?
    var transcriptObjectKey: String?
    var summaryObjectKey: String?

    init(from meeting: MeetingRecord) {
        self.id = meeting.id
        self.title = meeting.title
        self.startDate = meeting.startDate
        self.duration = meeting.duration
        self.status = meeting.status
        self.audioObjectKey = meeting.audioObjectKey
        self.transcriptObjectKey = meeting.transcriptObjectKey
        self.summaryObjectKey = meeting.summaryObjectKey
    }

    func toMeetingRecord() -> MeetingRecord {
        var record = MeetingRecord(
            id: id,
            title: title,
            startDate: startDate,
            duration: duration,
            status: status
        )
        record.audioObjectKey = audioObjectKey
        record.transcriptObjectKey = transcriptObjectKey
        record.summaryObjectKey = summaryObjectKey
        return record
    }
}

// MARK: - Defaults 序列化支持

extension MeetingRecord: Defaults.Serializable {}
extension MeetingStatus: Defaults.Serializable {}
extension TranscriptSegment: Defaults.Serializable {}
extension MeetingSummary: Defaults.Serializable {}
extension MeetingSummary.ChapterSummary: Defaults.Serializable {}
extension MeetingSummary.TodoItem: Defaults.Serializable {}
extension MeetingSummary.QAItem: Defaults.Serializable {}
