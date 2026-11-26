import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AIClientError: LocalizedError {
    case notConfigured(String)
    case invalidURL(String)
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let feature):
            return "「\(feature)」尚未配置 API Key 或模型名称，请前往设置面板完成配置。"
        case .invalidURL(let url):
            return "无效的 API 地址：\(url)"
        case .httpError(let code, let body):
            return "API 请求失败 (HTTP \(code))：\(body.prefix(300))"
        case .emptyResponse:
            return "模型未返回有效内容。"
        }
    }
}

final class AIClient {
    static let shared = AIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    func streamChat(
        feature: FeatureKind,
        messages: [ChatMessage],
        onThinkingChunk: ((String) -> Void)? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<(inputTokens: Int, outputTokens: Int), Error>) -> Void
    ) -> Task<Void, Never> {
        let config = SettingsStore.shared.config(for: feature)

        return Task {
            guard config.isConfigured else {
                let err = AIClientError.notConfigured(feature.displayName)
                AppLogger.shared.error(err.localizedDescription)
                await MainActor.run { onComplete(.failure(err)) }
                return
            }

            let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let endpointString = trimmedBase.hasSuffix("/chat/completions")
                ? trimmedBase
                : "\(trimmedBase)/chat/completions"

            guard let url = URL(string: endpointString) else {
                let err = AIClientError.invalidURL(endpointString)
                AppLogger.shared.error(err.localizedDescription)
                await MainActor.run { onComplete(.failure(err)) }
                return
            }

            var apiMessages: [[String: Any]] = []
            let sysPrompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sysPrompt.isEmpty {
                apiMessages.append(["role": "system", "content": sysPrompt])
            }

            var totalInputChars = sysPrompt.count
            for msg in messages {
                totalInputChars += msg.text.count
                if let imgData = msg.imageData {
                    let b64 = imgData.base64EncodedString()
                    let contentParts: [[String: Any]] = [
                        ["type": "text", "text": msg.text.isEmpty ? "请分析这张图片" : msg.text],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "auto"]]
                    ]
                    apiMessages.append(["role": msg.role, "content": contentParts])
                    totalInputChars += 1000 // approximate image token weight
                } else {
                    apiMessages.append(["role": msg.role, "content": msg.text])
                }
            }

            var body: [String: Any] = [
                "model": config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                "messages": apiMessages,
                "temperature": config.temperature,
                "stream": true,
                "stream_options": ["include_usage": true]
            ]

            let lowerURL = trimmedBase.lowercased()
            let lowerModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            Self.applyThinkingParameters(
                to: &body,
                enableThinking: config.enableThinking,
                effort: config.thinkingEffort,
                lowerURL: lowerURL,
                lowerModel: lowerModel
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                AppLogger.shared.error("JSON serialization failed: \(error.localizedDescription)")
                await MainActor.run { onComplete(.failure(error)) }
                return
            }

            let preview = messages.last?.text ?? feature.displayName
            var accumulatedOutput = ""
            var reportedPromptTokens: Int?
            var reportedCompletionTokens: Int?

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIClientError.emptyResponse
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                        if errorData.count > 4096 { break }
                    }
                    let errStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    let err = AIClientError.httpError(httpResponse.statusCode, errStr)
                    AppLogger.shared.error("API Error [\(feature.displayName) / \(config.modelName)]: \(err.localizedDescription)")
                    UsageStore.shared.recordUsage(
                        feature: feature,
                        config: config,
                        inputTokens: 0,
                        outputTokens: 0,
                        success: false,
                        previewText: preview
                    )
                    await MainActor.run { onComplete(.failure(err)) }
                    return
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let jsonData = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        continue
                    }

                    if let usage = json["usage"] as? [String: Any] {
                        if let pt = usage["prompt_tokens"] as? Int { reportedPromptTokens = pt }
                        if let ct = usage["completion_tokens"] as? Int { reportedCompletionTokens = ct }
                    }

                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let delta = first["delta"] as? [String: Any] {
                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            accumulatedOutput += reasoning
                            if let onThinking = onThinkingChunk {
                                await MainActor.run { onThinking(reasoning) }
                            }
                        }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            accumulatedOutput += content
                            await MainActor.run { onChunk(content) }
                        }
                    }
                }

                if Task.isCancelled { return }

                let estInput = reportedPromptTokens ?? max(16, Int(Double(totalInputChars) * 0.75))
                let estOutput = reportedCompletionTokens ?? max(8, Int(Double(accumulatedOutput.count) * 0.75))

                UsageStore.shared.recordUsage(
                    feature: feature,
                    config: config,
                    inputTokens: estInput,
                    outputTokens: estOutput,
                    success: true,
                    previewText: preview
                )
                AppLogger.shared.info("API OK [\(feature.displayName) / \(config.modelName)] in=\(estInput) out=\(estOutput)")
                await MainActor.run {
                    onComplete(.success((estInput, estOutput)))
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.shared.error("Network/Stream Error [\(feature.displayName)]: \(error.localizedDescription)")
                    UsageStore.shared.recordUsage(
                        feature: feature,
                        config: config,
                        inputTokens: 0,
                        outputTokens: 0,
                        success: false,
                        previewText: preview
                    )
                    await MainActor.run { onComplete(.failure(error)) }
                }
            }
        }
    }

    /// One-click connectivity test (includes a tiny valid JPEG probe for vision features!)
    func testConnection(
        for feature: FeatureKind,
        completion: @escaping (Result<(latencyMs: Int, replyPreview: String), Error>) -> Void
    ) {
        let config = SettingsStore.shared.config(for: feature)
        let startTime = Date()

        Task {
            guard config.isConfigured else {
                let err = AIClientError.notConfigured(feature.displayName)
                AppLogger.shared.error("Connection test FAILED [\(feature.displayName)]: \(err.localizedDescription)")
                await MainActor.run { completion(.failure(err)) }
                return
            }

            let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let endpointString = trimmedBase.hasSuffix("/chat/completions")
                ? trimmedBase
                : "\(trimmedBase)/chat/completions"

            guard let url = URL(string: endpointString) else {
                let err = AIClientError.invalidURL(endpointString)
                AppLogger.shared.error("Connection test FAILED [\(feature.displayName)]: \(err.localizedDescription)")
                await MainActor.run { completion(.failure(err)) }
                return
            }

            let userMessage: [String: Any]
            if feature.isVisionCapable, let tinyJPEG = Self.makeTinyTestJPEG() {
                let b64 = tinyJPEG.base64EncodedString()
                userMessage = [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Reply with OK"],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "low"]]
                    ]
                ]
            } else {
                userMessage = ["role": "user", "content": "Reply with OK"]
            }

            let lowerURL = trimmedBase.lowercased()
            let lowerModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var body: [String: Any] = [
                "model": config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                "messages": [userMessage],
                "max_tokens": 16,
                "stream": false
            ]
            Self.applyThinkingParameters(
                to: &body,
                enableThinking: false,
                effort: .low,
                lowerURL: lowerURL,
                lowerModel: lowerModel
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await session.data(for: request)
                let latency = Int(Date().timeIntervalSince(startTime) * 1000)

                guard let http = response as? HTTPURLResponse else {
                    throw AIClientError.emptyResponse
                }
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                if !(200...299).contains(http.statusCode) {
                    let err = AIClientError.httpError(http.statusCode, rawBody)
                    AppLogger.shared.error("Connection test FAILED [\(feature.displayName) / \(config.modelName)] (\(latency)ms): \(err.localizedDescription)")
                    await MainActor.run { completion(.failure(err)) }
                    return
                }

                var reply = "OK"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    reply = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                AppLogger.shared.info("Connection test OK [\(feature.displayName) / \(config.modelName)] (\(latency)ms) reply=\"\(reply.prefix(30))\"")
                await MainActor.run {
                    completion(.success((latency, reply.isEmpty ? "OK" : String(reply.prefix(40)))))
                }
            } catch {
                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                AppLogger.shared.error("Connection test FAILED [\(feature.displayName) / \(config.modelName)] (\(latency)ms): \(error.localizedDescription)")
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Applies provider- and model-aware thinking/reasoning flags across all 7 features (works on official endpoints AND third-party relays like PackCode/NewAPI/OneAPI)
    private static func applyThinkingParameters(
        to body: inout [String: Any],
        enableThinking: Bool,
        effort: ThinkingEffort,
        lowerURL: String,
        lowerModel: String
    ) {
        let isOfficialOpenAI = lowerURL.contains("api.openai.com")
        let isOfficialDeepSeek = lowerURL.contains("api.deepseek.com")

        let usesEnableThinkingBool = lowerURL.contains("siliconflow")
            || lowerURL.contains("dashscope")
            || lowerModel.contains("qwen")
            || lowerModel.contains("qwq")
            || lowerModel.contains("kimi")

        let usesThinkingDict = lowerURL.contains("volces.com")
            || lowerURL.contains("ark")
            || lowerModel.contains("doubao")
            || lowerModel.contains("glm")
            || lowerModel.contains("claude")

        let isGemini = lowerModel.contains("gemini")

        if enableThinking {
            body["reasoning_effort"] = effort.rawValue
            if usesEnableThinkingBool {
                body["enable_thinking"] = true
            }
            if usesThinkingDict {
                body["thinking"] = ["type": "enabled"]
            }
        } else {
            if usesEnableThinkingBool {
                body["enable_thinking"] = false
            }
            if usesThinkingDict {
                body["thinking"] = ["type": "disabled"]
            }
            if isGemini && !isOfficialOpenAI && !isOfficialDeepSeek {
                body["reasoning_effort"] = "none"
            }
        }
    }

    private static func makeTinyTestJPEG() -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let cgImg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
