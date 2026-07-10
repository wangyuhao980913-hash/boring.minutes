//
//  TOSStorageService.swift
//  boringNotch
//
//  火山引擎 TOS 对象存储服务（S3 兼容 REST API）
//  用于上传会议录音、转录、总结到云端
//

import CommonCrypto
import Defaults
import Foundation

class TOSStorageService {
    static let shared = TOSStorageService()

    private var accessKeyId: String { Defaults[.tosAccessKeyId] }
    private var secretAccessKey: String { Defaults[.tosSecretAccessKey] }
    private var bucketName: String { Defaults[.tosBucketName] }
    private var region: String { Defaults[.tosRegion] }

    private var endpoint: String {
        "tos-s3-\(region).volces.com"
    }

    var isConfigured: Bool {
        !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !bucketName.isEmpty
    }

    private let session = URLSession.shared

    // MARK: - 上传文件

    func uploadFile(localURL: URL, objectKey: String) async throws -> String {
        let fileData = try Data(contentsOf: localURL)
        return try await uploadData(fileData, objectKey: objectKey, contentType: mimeType(for: localURL.pathExtension))
    }

    // MARK: - 上传数据

    func uploadData(_ data: Data, objectKey: String, contentType: String = "application/octet-stream") async throws -> String {
        let url = URL(string: "https://\(bucketName).\(endpoint)/\(uriEncodePath(objectKey))")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        signRequest(&request, method: "PUT", objectKey: objectKey, payloadHash: sha256Hex(data))

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TOSError.uploadFailed(statusCode: statusCode)
        }

        return objectKey
    }

    // MARK: - 凭证验证（上传一个极小健康检查对象再删除，真实往返校验 AK/SK/桶/区域）

    func validateCredentials() async -> (Bool, String) {
        guard isConfigured else { return (false, "未填写 TOS Access Key / Secret Key / Bucket") }
        let key = "meetings/_healthcheck/\(UUID().uuidString).txt"
        do {
            _ = try await uploadData(Data("ok".utf8), objectKey: key, contentType: "text/plain")
            try? await deleteObject(objectKey: key)
            return (true, "TOS 连接正常（\(bucketName) @ \(region)）")
        } catch {
            return (false, "TOS 连接失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 下载对象（用于拉取云端会议清单）

    /// GET 指定对象；对象不存在（HTTP 404）时返回 nil，其它非 2xx 抛错。
    func downloadData(objectKey: String) async throws -> Data? {
        let url = URL(string: "https://\(bucketName).\(endpoint)/\(uriEncodePath(objectKey))")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        signRequest(&request, method: "GET", objectKey: objectKey, payloadHash: sha256Hex(Data()))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TOSError.downloadFailed(statusCode: 0)
        }
        if httpResponse.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TOSError.downloadFailed(statusCode: httpResponse.statusCode)
        }
        return data
    }

    // MARK: - 生成预签名 URL（用于妙记 API 提交和音频回放）

    func presignedURL(objectKey: String, expiration: TimeInterval = 3600) -> URL? {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        let now = Date()
        let amzDate = dateFmt.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        let credential = "\(accessKeyId)/\(dateStamp)/\(region)/s3/aws4_request"
        let expirationStr = String(Int(expiration))

        // SigV4 预签名要求查询参数值按 RFC3986 严格编码（含 "/" -> %2F），
        // 且签名用的规范串与最终 URL 必须用同一份编码，否则服务端验签失败(403)。
        let canonicalQueryString = [
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=\(awsURIEncode(credential))",
            "X-Amz-Date=\(amzDate)",
            "X-Amz-Expires=\(expirationStr)",
            "X-Amz-SignedHeaders=host",
        ].joined(separator: "&")

        let host = "\(bucketName).\(endpoint)"
        let encodedKey = uriEncodePath(objectKey)
        let canonicalRequest = [
            "GET",
            "/\(encodedKey)",
            canonicalQueryString,
            "host:\(host)",
            "",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            "\(dateStamp)/\(region)/s3/aws4_request",
            sha256Hex(canonicalRequest.data(using: .utf8)!),
        ].joined(separator: "\n")

        let signingKey = getSignatureKey(dateStamp: dateStamp)
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign.data(using: .utf8)!)

        let signedURL = "https://\(host)/\(encodedKey)?\(canonicalQueryString)&X-Amz-Signature=\(signature)"
        return URL(string: signedURL)
    }

    // MARK: - 删除对象

    func deleteObject(objectKey: String) async throws {
        let url = URL(string: "https://\(bucketName).\(endpoint)/\(uriEncodePath(objectKey))")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        signRequest(&request, method: "DELETE", objectKey: objectKey, payloadHash: sha256Hex(Data()))

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) || httpResponse.statusCode == 404
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TOSError.deleteFailed(statusCode: statusCode)
        }
    }

    // MARK: - 列举对象（S3 ListObjectsV2）

    /// 列出指定前缀下的所有 CommonPrefixes（子目录），用分隔符 "/" 分层。
    /// 例如 `prefix = "meetings/"` 会返回 `["meetings/{uuid1}/", "meetings/{uuid2}/", ...]`。
    /// 自动处理分页（ContinuationToken）。
    func listCommonPrefixes(prefix: String, delimiter: String = "/") async throws -> [String] {
        var result: [String] = []
        var continuationToken: String? = nil

        repeat {
            var queryItems = "list-type=2&prefix=\(awsURIEncode(prefix))&delimiter=\(awsURIEncode(delimiter))"
            if let token = continuationToken {
                queryItems += "&continuation-token=\(awsURIEncode(token))"
            }

            let urlString = "https://\(bucketName).\(endpoint)/?\(queryItems)"
            guard let url = URL(string: urlString) else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            signListRequest(&request, queryString: queryItems)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw TOSError.downloadFailed(statusCode: code)
            }

            let xml = String(data: data, encoding: .utf8) ?? ""
            result.append(contentsOf: parseXMLElements(xml, tag: "Prefix", parentTag: "CommonPrefixes"))

            if xml.contains("<IsTruncated>true</IsTruncated>"),
               let token = parseXMLElement(xml, tag: "NextContinuationToken")
            {
                continuationToken = token
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil

        return result
    }

    /// 列出指定前缀下的所有对象 key（不含目录分隔，用于批量删除）。
    func listObjectKeys(prefix: String) async throws -> [String] {
        var result: [String] = []
        var continuationToken: String? = nil

        repeat {
            var queryItems = "list-type=2&prefix=\(awsURIEncode(prefix))"
            if let token = continuationToken {
                queryItems += "&continuation-token=\(awsURIEncode(token))"
            }

            let urlString = "https://\(bucketName).\(endpoint)/?\(queryItems)"
            guard let url = URL(string: urlString) else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            signListRequest(&request, queryString: queryItems)

            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            guard let httpResponse, (200..<300).contains(httpResponse.statusCode) else {
                let code = httpResponse?.statusCode ?? 0
                NSLog("[TOS] listObjectKeys 失败: prefix=\"%@\" HTTP %d", prefix, code)
                throw TOSError.downloadFailed(statusCode: code)
            }

            let xml = String(data: data, encoding: .utf8) ?? ""
            result.append(contentsOf: parseXMLElements(xml, tag: "Key", parentTag: "Contents"))

            if xml.contains("<IsTruncated>true</IsTruncated>"),
               let token = parseXMLElement(xml, tag: "NextContinuationToken")
            {
                continuationToken = token
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil

        NSLog("[TOS] listObjectKeys: prefix=\"%@\" 共发现 %d 个对象", prefix, result.count)
        return result
    }

    /// 删除指定前缀下的所有对象（先列举再逐个删除）。
    func deleteAllObjects(withPrefix prefix: String) async throws {
        let keys = try await listObjectKeys(prefix: prefix)
        var failedKeys: [(String, Error)] = []
        for key in keys {
            do {
                try await deleteObject(objectKey: key)
            } catch {
                failedKeys.append((key, error))
                NSLog("[TOS] deleteObject 失败: key=\"%@\" error=%@", key, error.localizedDescription)
            }
        }
        if !failedKeys.isEmpty {
            NSLog("[TOS] deleteAllObjects: %d/%d 个对象删除失败 (prefix=\"%@\")", failedKeys.count, keys.count, prefix)
        } else if !keys.isEmpty {
            NSLog("[TOS] deleteAllObjects: prefix=\"%@\" 全部 %d 个对象删除成功", prefix, keys.count)
        }
    }

    /// 对 ListObjectsV2 请求签名（objectKey 为空，查询参数参与签名）。
    private func signListRequest(_ request: inout URLRequest, queryString: String) {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        let now = Date()
        let amzDate = dateFmt.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        let host = "\(bucketName).\(endpoint)"
        let payloadHash = sha256Hex(Data())

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = [
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)",
        ].joined(separator: "\n")

        // 查询参数必须按 key 字母序排列后参与签名
        let sortedQuery = queryString.split(separator: "&").sorted().joined(separator: "&")

        let canonicalRequest = [
            "GET",
            "/",
            sortedQuery,
            canonicalHeaders,
            "",
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.data(using: .utf8)!),
        ].joined(separator: "\n")

        let signingKey = getSignatureKey(dateStamp: dateStamp)
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign.data(using: .utf8)!)

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - 简易 XML 解析

    /// 从 XML 中提取指定父标签下的子标签文本值。
    /// 例如 parseXMLElements(xml, tag: "Prefix", parentTag: "CommonPrefixes") 会提取所有
    /// `<CommonPrefixes><Prefix>...</Prefix></CommonPrefixes>` 中的文本。
    private func parseXMLElements(_ xml: String, tag: String, parentTag: String) -> [String] {
        var results: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex

        let parentOpen = "<\(parentTag)>"
        let parentClose = "</\(parentTag)>"
        let tagOpen = "<\(tag)>"
        let tagClose = "</\(tag)>"

        while let parentStart = xml.range(of: parentOpen, range: searchRange),
              let parentEnd = xml.range(of: parentClose, range: parentStart.upperBound..<xml.endIndex)
        {
            let block = xml[parentStart.upperBound..<parentEnd.lowerBound]
            if let tStart = block.range(of: tagOpen),
               let tEnd = block.range(of: tagClose, range: tStart.upperBound..<block.endIndex)
            {
                results.append(String(block[tStart.upperBound..<tEnd.lowerBound]))
            }
            searchRange = parentEnd.upperBound..<xml.endIndex
        }
        return results
    }

    /// 从 XML 中提取单个标签的文本值。
    private func parseXMLElement(_ xml: String, tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = xml.range(of: open),
              let end = xml.range(of: close, range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    // MARK: - AWS Signature V4 签名

    private func signRequest(_ request: inout URLRequest, method: String, objectKey: String, payloadHash: String) {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        let now = Date()
        let amzDate = dateFmt.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        let host = "\(bucketName).\(endpoint)"

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = [
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)",
        ].joined(separator: "\n")

        let canonicalRequest = [
            method,
            "/\(uriEncodePath(objectKey))",
            "",
            canonicalHeaders,
            "",
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.data(using: .utf8)!),
        ].joined(separator: "\n")

        let signingKey = getSignatureKey(dateStamp: dateStamp)
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign.data(using: .utf8)!)

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - URI 编码

    /// 对对象键做 AWS SigV4 规范的路径编码：保留 "/" 分隔符，其余非 unreserved 字符按 %XX 编码。
    /// 必须在「构造请求 URL」和「计算签名的规范路径」两处使用同一份编码，否则验签失败。
    private func uriEncodePath(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    /// RFC3986 严格编码（用于查询参数值），连 "/" 也编码成 %2F。
    private func awsURIEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 加密工具

    private func getSignatureKey(dateStamp: String) -> Data {
        let kDate = hmacSHA256(key: "AWS4\(secretAccessKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: region.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: "s3".data(using: .utf8)!)
        return hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyPtr.baseAddress, key.count, dataPtr.baseAddress, data.count, &hmac)
            }
        }
        return Data(hmac)
    }

    private func hmacSHA256Hex(key: Data, data: Data) -> String {
        hmacSHA256(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m4a": return "audio/mp4"
        case "json": return "application/json"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 错误类型

enum TOSError: LocalizedError {
    case uploadFailed(statusCode: Int)
    case downloadFailed(statusCode: Int)
    case deleteFailed(statusCode: Int)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let code): return "TOS 上传失败 (HTTP \(code))"
        case .downloadFailed(let code): return "TOS 下载失败 (HTTP \(code))"
        case .deleteFailed(let code): return "TOS 删除失败 (HTTP \(code))"
        case .notConfigured: return "TOS 未配置"
        }
    }
}
