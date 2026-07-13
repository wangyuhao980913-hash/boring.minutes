//
//  DoubaoMiaojiService.swift
//  boringNotch
//
//  豆包语音妙记 API（飞书妙记同款）
//  文档: https://www.volcengine.com/docs/6561/1798094
//

import Defaults
import Foundation

class DoubaoMiaojiService {
    static let shared = DoubaoMiaojiService()

    private let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/lark/submit")!
    private let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/lark/query")!
    private let resourceId = "volc.lark.minutes"

    private var appId: String { Defaults[.miaojiAppId] }
    private var accessToken: String { Defaults[.miaojiAccessToken] }

    private let session = URLSession.shared

    var isConfigured: Bool {
        !appId.isEmpty && !accessToken.isEmpty
    }

    // MARK: - 凭证验证（启发式：用一个不存在的 TaskID 发 query，看鉴权是否通过）

    func validateCredentials() async -> (Bool, String) {
        guard isConfigured else {
            return (false, "未填写妙记 App ID / Access Token")
        }
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["TaskID": "healthcheck-\(UUID().uuidString)"])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&request, requestId: UUID().uuidString)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "网络错误")
            }
            let status = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
            let message = (http.value(forHTTPHeaderField: "X-Api-Message") ?? "").lowercased()

            // 鉴权类失败关键字：说明 App ID / Token 有问题
            let authKeywords = ["auth", "token", "access key", "accesskey", "app key", "appkey", "permission", "denied", "unauthorized", "signature"]
            if authKeywords.contains(where: { message.contains($0) }) {
                let raw = http.value(forHTTPHeaderField: "X-Api-Message") ?? status
                return (false, "妙记鉴权失败：\(raw)")
            }
            // 其它情况（如"任务不存在"）说明鉴权已通过
            return (true, "妙记鉴权已通过（凭证有效）")
        } catch {
            return (false, "妙记连接失败：\(error.localizedDescription)")
        }
    }

    func submitAndWait(
        audioURL: String,
        language: String,
        maxWaitSeconds: Int = 600,
        pollInterval: TimeInterval = 30
    ) async throws -> MiaojiFullResult? {
        let taskId = try await submitTask(audioURL: audioURL, language: language)
        return try await waitForResult(
            taskId: taskId,
            maxWaitSeconds: maxWaitSeconds,
            pollInterval: pollInterval
        )
    }

    func submitTask(audioURL: String, language: String) async throws -> String {
        guard isConfigured else { throw MiaojiError.notConfigured }

        let requestId = UUID().uuidString
        let sourceLang = mapLanguage(language)

        let payload: [String: Any] = [
            "Input": [
                "Offline": [
                    "FileURL": audioURL,
                    "FileType": "audio",
                ],
            ],
            "Params": [
                "AllActivate": true,
                "SourceLang": sourceLang,
                "AudioTranscriptionEnable": true,
                "AudioTranscriptionParams": [
                    "SpeakerIdentification": true,
                    "NumberOfSpeaker": 0,
                    "NeedWordTimeSeries": false,
                ],
                "InformationExtractionEnabled": true,
                "InformationExtractionParams": [
                    "Types": ["todo_list", "question_answer"],
                ],
                "SummarizationEnabled": true,
                "SummarizationParams": [
                    "Types": ["summary"],
                ],
                "ChapterEnabled": true,
            ],
        ]

        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&request, requestId: requestId)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiaojiError.networkError
        }

        logResponse("妙记 submit", httpResponse, data: data)

        let statusCode = httpResponse.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        guard statusCode == "20000000" else {
            let message = httpResponse.value(forHTTPHeaderField: "X-Api-Message") ?? "Unknown error"
            throw MiaojiError.submitFailed(message: message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["Data"] as? [String: Any],
              let taskId = dataObj["TaskID"] as? String,
              !taskId.isEmpty
        else {
            throw MiaojiError.submitFailed(message: "响应中缺少 TaskID")
        }

        return taskId
    }

    func queryResult(taskId: String) async throws -> MiaojiQueryResult {
        guard isConfigured else { throw MiaojiError.notConfigured }

        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["TaskID": taskId])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&request, requestId: taskId)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiaojiError.networkError
        }

        logResponse("妙记 query", httpResponse, data: data)

        let apiStatus = httpResponse.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["Data"] as? [String: Any]
        else {
            let message = httpResponse.value(forHTTPHeaderField: "X-Api-Message") ?? "解析响应失败"
            return .failed(message)
        }

        let status = (dataObj["Status"] as? String ?? "").lowercased()
        let errCode = dataObj["ErrCode"] as? Int ?? 0
        let errMessage = dataObj["ErrMessage"] as? String ?? ""
        NSLog("[妙记 query] Status=%@ ErrCode=%d ErrMessage=%@", status, errCode, errMessage)

        switch status {
        case "success":
            guard apiStatus == "20000000" || apiStatus.isEmpty else {
                let message = httpResponse.value(forHTTPHeaderField: "X-Api-Message") ?? apiStatus
                return .failed(message)
            }
            let result = try await parseLarkResult(dataObj)
            return .completed(result)

        case "failed":
            let errCode = dataObj["ErrCode"] as? Int ?? 0
            let errMessage = dataObj["ErrMessage"] as? String ?? "任务失败"
            NSLog("[妙记 query] 任务失败详情: ErrCode=%d ErrMessage=%@", errCode, errMessage)
            return .failed("\(errCode): \(errMessage)")

        case "running":
            return .processing

        default:
            if apiStatus == "20000001" || apiStatus == "20000002" {
                return .processing
            }
            return .processing
        }
    }

    func waitForResult(
        taskId: String,
        maxWaitSeconds: Int = 600,
        pollInterval: TimeInterval = 30
    ) async throws -> MiaojiFullResult? {
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))

        while Date() < deadline {
            let result = try await queryResult(taskId: taskId)

            switch result {
            case .completed(let fullResult):
                return fullResult
            case .processing:
                try await Task.sleep(for: .seconds(pollInterval))
            case .failed(let message):
                throw MiaojiError.queryFailed(message: message)
            }
        }

        throw MiaojiError.timeout
    }

    private func parseLarkResult(_ dataObj: [String: Any]) async throws -> MiaojiFullResult {
        guard let resultObj = dataObj["Result"] as? [String: Any] else {
            return MiaojiFullResult(text: "", segments: [], summary: nil, suggestedTitle: nil)
        }

        var segments: [TranscriptSegment] = []
        var summary = MeetingSummary()
        var suggestedTitle: String?

        if let transcriptURL = resultObj["AudioTranscriptionFile"] as? String,
           let url = URL(string: transcriptURL)
        {
            segments = try await parseTranscriptFile(from: url)
        }

        if let summaryURL = resultObj["SummarizationFile"] as? String,
           let url = URL(string: summaryURL)
        {
            let (title, paragraph) = try await parseSummarizationFile(from: url)
            summary.fullSummary = paragraph
            suggestedTitle = title
        }

        if let chapterURL = resultObj["ChapterFile"] as? String,
           let url = URL(string: chapterURL)
        {
            NSLog("MiaojiChapter: Result 里有 ChapterFile，URL=\(url.absoluteString)")
            let parsed = try await parseChapterFile(from: url)
            summary.chapters = parsed
            NSLog("MiaojiChapter: 解析出 \(parsed.count) 条章节")
        } else {
            NSLog("MiaojiChapter: Result 里没有 ChapterFile 字段（API 未返回章节）。Result 顶层键=\(Array(resultObj.keys))")
        }

        if let extractionURL = resultObj["InformationExtractionFile"] as? String,
           let url = URL(string: extractionURL)
        {
            let (todos, qas) = try await parseExtractionFile(from: url, segments: segments)
            summary.todoItems = todos
            summary.qaItems = qas
        }

        let fullText = segments.map(\.text).joined()

        return MiaojiFullResult(
            text: fullText,
            segments: segments,
            summary: summary.hasContent ? summary : nil,
            suggestedTitle: suggestedTitle
        )
    }

    private func parseTranscriptFile(from url: URL) async throws -> [TranscriptSegment] {
        let data = try await downloadJSON(from: url)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> TranscriptSegment? in
            guard let text = item["content"] as? String, !text.isEmpty else { return nil }

            let startMs = numericValue(item["start_time"])
            let endMs = numericValue(item["end_time"])

            var speaker: String?
            if let speakerObj = item["speaker"] as? [String: Any] {
                speaker = speakerObj["name"] as? String
                if speaker?.isEmpty == true {
                    if let id = speakerObj["id"] {
                        speaker = "说话人\(id)"
                    }
                }
            }

            return TranscriptSegment(
                startTime: startMs / 1000.0,
                endTime: endMs / 1000.0,
                text: text,
                speaker: speaker,
                isFinal: true
            )
        }
    }

    private func parseSummarizationFile(from url: URL) async throws -> (String?, String?) {
        let data = try await downloadJSON(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let title = json["title"] as? String
        let paragraph = json["paragraph"] as? String
        return (title, paragraph)
    }

    private func parseChapterFile(from url: URL) async throws -> [MeetingSummary.ChapterSummary] {
        let data = try await downloadJSON(from: url)
        let rawObj = try? JSONSerialization.jsonObject(with: data)
        guard let json = rawObj as? [String: Any] else {
            NSLog("MiaojiChapter: 章节 JSON 顶层不是对象，无法解析。原始片段=\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            return []
        }

        // 妙记不同版本返回的章节数组键名可能不同，依次尝试常见备选键，取到第一个是数组的即用
        let candidateKeys = ["chapter_summary", "chapters", "chapter_list", "chapter"]
        var chapters: [[String: Any]]?
        var matchedKey: String?
        for key in candidateKeys {
            if let arr = json[key] as? [[String: Any]] {
                chapters = arr
                matchedKey = key
                break
            }
        }

        guard let chapters, let matchedKey else {
            NSLog("MiaojiChapter: 下载到章节 JSON，但备选键 \(candidateKeys) 均未命中。顶层键=\(Array(json.keys))")
            return []
        }
        NSLog("MiaojiChapter: 命中键=\(matchedKey)，原始条数=\(chapters.count)")

        let parsed = chapters.compactMap { ch -> MeetingSummary.ChapterSummary? in
            // 标题字段做多名兼容，任一非空即可；都没有则跳过该条
            let title = (ch["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (ch["chapter_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (ch["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let title else { return nil }

            // 摘要字段做多名兼容，缺省空串
            let summary = (ch["summary"] as? String)
                ?? (ch["content"] as? String)
                ?? (ch["abstract"] as? String)
                ?? ""

            // 时间字段做多名兼容，单位毫秒，除以 1000 得秒
            let startMs = numericValue(ch["start_time"] ?? ch["start"] ?? ch["begin_time"])
            let endMs = numericValue(ch["end_time"] ?? ch["end"])

            return MeetingSummary.ChapterSummary(
                title: title,
                summary: summary,
                startTime: startMs / 1000.0,
                endTime: endMs / 1000.0
            )
        }
        NSLog("MiaojiChapter: 命中键=\(matchedKey)，成功解析出 \(parsed.count) 条章节")
        return parsed
    }

    private func parseExtractionFile(
        from url: URL,
        segments: [TranscriptSegment]
    ) async throws -> ([MeetingSummary.TodoItem], [MeetingSummary.QAItem]) {
        let data = try await downloadJSON(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }

        var todos: [MeetingSummary.TodoItem] = []
        if let todoList = json["todo_list"] as? [[String: Any]] {
            for item in todoList {
                let content: String
                if let polished = item["polished_res"] as? [String: Any],
                   let polishedContent = polished["content"] as? String,
                   !polishedContent.isEmpty
                {
                    content = polishedContent
                } else if let raw = item["content"] as? String, !raw.isEmpty {
                    content = raw
                } else {
                    continue
                }

                var assignee: String?
                if let executor = item["executor"] as? String, !executor.isEmpty, executor != "无" {
                    assignee = executor
                } else if let polished = item["polished_res"] as? [String: Any],
                          let executors = polished["executor"] as? [String],
                          let first = executors.first, !first.isEmpty, first != "无"
                {
                    assignee = first
                }

                todos.append(MeetingSummary.TodoItem(assignee: assignee, content: content))
            }
        }

        var qas: [MeetingSummary.QAItem] = []
        if let questions = json["question"] as? [[String: Any]] {
            let segmentByIndex = Dictionary(
                uniqueKeysWithValues: segments.enumerated().map { (String($0.offset), $0.element) }
            )

            for q in questions {
                guard let sentenceId = q["sentence_id"] as? String,
                      let segment = segmentByIndex[sentenceId]
                else { continue }

                let label = q["label"] as? Int ?? 0
                if label == 3 || label == 2 {
                    qas.append(MeetingSummary.QAItem(
                        question: segment.text,
                        answer: "（见会议记录对应时段）"
                    ))
                }
            }
        }

        return (todos, qas)
    }

    private func applyAuthHeaders(_ request: inout URLRequest, requestId: String) {
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
    }

    private func mapLanguage(_ language: String) -> String {
        switch language.lowercased() {
        case "en-us", "en_us", "en":
            return "en_us"
        default:
            return "zh_cn"
        }
    }

    private func downloadJSON(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MiaojiError.downloadFailed(url: url.absoluteString, statusCode: code)
        }
        return data
    }

    private func numericValue(_ value: Any?) -> Double {
        switch value {
        case let n as Int: return Double(n)
        case let n as Double: return n
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    private func logResponse(_ tag: String, _ response: HTTPURLResponse, data: Data) {
        let status = response.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let message = response.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        let logId = response.value(forHTTPHeaderField: "X-Tt-Logid") ?? ""
        let body = String(data: data, encoding: .utf8) ?? ""
        NSLog("\(tag): status=\(status) msg=\(message) logId=\(logId) body=\(body.prefix(500))")
    }
}

enum MiaojiQueryResult {
    case completed(MiaojiFullResult)
    case processing
    case failed(String)
}

struct MiaojiFullResult {
    var text: String
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?
    var suggestedTitle: String?
}

enum MiaojiError: LocalizedError {
    case notConfigured
    case submitFailed(message: String)
    case queryFailed(message: String)
    case networkError
    case timeout
    case downloadFailed(url: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "妙记未配置 App ID 或 Access Token"
        case .submitFailed(let msg): return "妙记提交失败: \(msg)"
        case .queryFailed(let msg): return "妙记查询失败: \(msg)"
        case .networkError: return "网络错误"
        case .timeout: return "妙记处理超时"
        case .downloadFailed(let url, let code): return "下载结果失败 (HTTP \(code)): \(url)"
        }
    }
}

private extension MeetingSummary {
    var hasContent: Bool {
        if let s = fullSummary, !s.isEmpty { return true }
        if let c = chapters, !c.isEmpty { return true }
        if let t = todoItems, !t.isEmpty { return true }
        if let q = qaItems, !q.isEmpty { return true }
        return false
    }
}
