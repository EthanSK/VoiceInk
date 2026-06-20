import Foundation
import os

class OpenAICompatibleTranscriptionService {
    // VIPPDebug: client-side view of the local Deepgram proxy round-trip. Pairs with the
    // proxy's own 200/500-BrokenPipe log so we can tell, from the APP side, whether an
    // upload completed (200), failed, or was CANCELLED mid-flight (URLError.cancelled →
    // the BrokenPipe the proxy sees). Filter:
    //   log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    // Dedicated URLSession with EXTENDED timeouts instead of URLSession.shared.
    // WHY: URLSession.shared uses the default 60s request timeout. OpenAI-compatible
    // proxies (esp. ones doing their own upstream retries) can hold a multipart audio
    // upload open well past 60s, and tripping the 60s wall mid-proxy-retry surfaced as
    // intermittent BrokenPipe / 500 errors — a transient timeout masquerading as a
    // server failure. 180s per-request + 300s per-resource gives slow proxies room to
    // finish without changing any success-path behavior.
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180   // per-request inactivity window (was default 60s)
        cfg.timeoutIntervalForResource = 300  // total wall-clock cap for the whole upload+response
        return URLSession(configuration: cfg)
    }()

    func transcribe(audioURL: URL, model: CustomCloudModel, context: TranscriptionRequestContext) async throws -> String {
        guard let url = URL(string: model.apiEndpoint) else {
            throw NSError(domain: "CustomWhisperTranscriptionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint URL"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")

        let body = try buildRequestBody(audioURL: audioURL, modelName: model.modelName, boundary: boundary, context: context)
        vippLog.info("cloud upload START endpoint=\(model.apiEndpoint, privacy: .public) bytes=\(body.count, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, from: body)
        } catch {
            // VIPPDebug: an error here with URLError.cancelled is the BrokenPipe-500 case:
            // the enclosing Task (key-event / pipeline) was cancelled, so URLSession aborts
            // the upload and the proxy sees the client close the socket. Any other error is
            // a genuine network failure / timeout. Re-throw unchanged.
            let isCancelled = (error as? URLError)?.code == .cancelled
            vippLog.error("cloud upload THREW isCancelled=\(isCancelled, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            vippLog.error("cloud upload END non-HTTP response")
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }

        vippLog.info("cloud upload END status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")

        if !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = String(data: data, encoding: .utf8) ?? "No error message"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
        } catch {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
    }

    private func buildRequestBody(audioURL: URL, modelName: String, boundary: String, context: TranscriptionRequestContext) throws -> Data {
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw CloudTranscriptionError.audioFileNotFound
        }

        let selectedLanguage = context.language ?? "auto"
        let prompt = context.prompt ?? ""
        let crlf = "\r\n"
        var body = Data()

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            body.append(value.data(using: .utf8)!)
            append(crlf)
        }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        field("model", modelName)
        field("response_format", "json")
        field("temperature", "0")

        if selectedLanguage != "auto" && !selectedLanguage.isEmpty {
            field("language", selectedLanguage)
        }
        if !prompt.isEmpty {
            field("prompt", prompt)
        }

        append("--\(boundary)--\(crlf)")
        return body
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let language: String?
        let duration: Double?
    }
}
