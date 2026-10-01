#!/usr/bin/env swift
// LazyKit AI peer reviewer: progressive-disclosure skills, CommandCode JSON
// findings, GitHub PR review with inline threads + suggestion blocks.
//
// Skills load the way Claude Code and Codex load them. The system prompt
// carries only the catalogue — every skill's name and the conditions that make
// it relevant — and the model calls `load_skill` to read a body when the diff
// makes one relevant. Nothing is routed ahead of time, so the model can pull a
// second skill after reading the first, and a body it never asks for costs
// nothing.
//
// Talks to the CommandCode Provider API, which speaks OpenAI Chat Completions:
//     POST https://api.commandcode.ai/provider/v1/chat/completions
//     Authorization: Bearer $COMMANDCODE_API_KEY
//
// Foundation only, no dependencies, so it runs as a plain script:
//     swift .github/scripts/ai_review.swift --diff pr.diff ...
//
// JSON handling follows what each surface demands rather than one rule for all:
//
//   * the request payload and the GitHub review body are `Encodable` structs,
//     because we own those shapes;
//   * the chat-completion envelope is a `Decodable` struct, because the protocol
//     owns that shape;
//   * the model's review output is decoded leniently — every field optional, and
//     `findings` through a `Lossy` wrapper so one malformed finding cannot
//     discard the whole review;
//   * the echoed assistant turn is kept as raw `JSONValue`. Decoding it into the
//     modelled fields and re-encoding would silently drop anything this file does
//     not know about, and the API requires that turn back verbatim.
//
// Never fails the workflow (advisory only): all errors print a notice and exit
// 0 so the review can never block a merge.
//
// Usage (CI):
//     swift .github/scripts/ai_review.swift \
//         --diff pr.diff --pr-number 12 --repo owner/name --commit <head-sha> \
//         --output review.md [--post]
//
// Local:
//     git diff origin/main...HEAD > /tmp/pr.diff
//     COMMANDCODE_API_KEY=... swift .github/scripts/ai_review.swift \
//         --diff /tmp/pr.diff --pr-number 0 --repo local/test --no-post
//

import Dispatch
import Foundation

// URLSession, URLRequest and HTTPURLResponse live in FoundationNetworking on
// Linux, not in Foundation. Without this the script compiles on macOS and fails
// on the CI runner.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Constants

let skipPrefixes = ["Package.resolved", "Package.lock", ".build/", "DerivedData/", ".swiftpm/"]
let skipSuffixes = [
    ".lock", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".xcresult", ".DS_Store", ".xcuserstate",
]

let defaultModel = "deepseek/deepseek-v4.1-flash"
let apiURL = "https://api.commandcode.ai/provider/v1/chat/completions"
let modelsURL = "https://api.commandcode.ai/provider/v1/models"
let chatEndpoint = "/chat/completions"

// Cloudflare fronts the CommandCode API and answers 403 "error code: 1010" to
// requests with no User-Agent. Any explicit UA clears it; without this every
// request fails and the review silently degrades to "unavailable".
let userAgent = "LazyKit-AI-Review/1.0 (+https://github.com/rafattouqir/LazyKit)"

/// Turns before the loop drops the tools and forces an answer.
let maxToolTurns = 5
/// HTTP statuses worth trying the next model on.
let fallthroughStatus: Set<Int> = [400, 404, 429]
let maxModelsTried = 4

let prereleaseRegex = try! NSRegularExpression(
    pattern: "preview|exp\\d*|experimental|beta|alpha|\\brc\\b|stealth", options: [.caseInsensitive])
let noiseRegex = try! NSRegularExpression(
    pattern: "embed|rerank|tts|whisper|image|video|moderation", options: [.caseInsensitive])

let severityEmoji = ["critical": "🔴", "high": "🟠", "medium": "🟡", "low": "🟢"]

// MARK: - Errors

struct ReviewFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The model or gateway refused a `tools` array.
///
/// Thrown so the caller can fall back to inlining every skill body, which is
/// strictly better than losing the review.
struct ToolsUnsupported: Error {
    let note: String
}

struct HTTPFailure: Error, CustomStringConvertible {
    let code: Int
    let note: String
    var description: String { "HTTP \(code) \(note)" }
}

// MARK: - Mutable run state
//
// Held in a reference type rather than top-level `var`s: the latches are mutated
// from inside `complete`, and a class keeps the compiler happy about shared
// mutable state in both Swift 5 and Swift 6 language modes.
final class Latches {
    /// Latches off the first time the API rejects the optional request params, so
    /// the tool loop and the fallback pass don't each rediscover the same 400.
    var optionalParamsOK = true
    /// Set once a tools array has been refused, so a later turn in the same run
    /// does not retry something we already know the model will not accept.
    var toolsOK = true
}

let latches = Latches()

// MARK: - JSON value

/// A lossless JSON tree.
///
/// The conformance is hand-written on purpose: Swift's synthesised `Codable` for
/// an enum with associated values emits a tagged form (`{"string": {"_0": …}}`)
/// that is not valid JSON, so it cannot be used for passthrough.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? { object?[key] }

    /// Compact JSON text for log lines and error messages.
    func preview(_ limit: Int = 500) -> String {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return String(text.prefix(limit))
    }

    static func message(role: String, content: String) -> JSONValue {
        .object(["role": .string(role), "content": .string(content)])
    }

    static func toolMessage(id: String, content: String) -> JSONValue {
        .object([
            "role": .string("tool"),
            "tool_call_id": .string(id),
            "content": .string(content),
        ])
    }
}

// MARK: - Wire types

/// `content` is a String on most gateways and `[Part]` on some. One `init(from:)`
/// absorbs both so nothing downstream has to care.
enum Content: Decodable {
    case text(String)
    case parts([Part])

    struct Part: Decodable { let text: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .parts((try? container.decode([Part].self)) ?? [])
        }
    }

    var plainText: String {
        switch self {
        case .text(let value): return value
        case .parts(let parts): return parts.compactMap(\.text).joined()
        }
    }
}

/// The `name` argument of a `load_skill` call.
struct SkillRequest: Decodable {
    let name: String
}

struct ToolCall: Decodable {
    let id: String?
    let function: Function?

    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }

    /// The skill the model asked for, or nil when the call is unusable.
    ///
    /// `arguments` is a JSON *string* nested inside JSON, so it takes a second
    /// decode. A call we cannot parse is not fatal: the caller answers it with
    /// the list of valid names.
    var skillName: String? {
        guard let arguments = function?.arguments,
            let data = arguments.data(using: .utf8),
            let request = try? JSONDecoder().decode(SkillRequest.self, from: data)
        else { return nil }
        return request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One assistant turn.
///
/// `raw` is the message exactly as it arrived. Decoding into the typed fields and
/// re-encoding would drop anything this struct does not model —
/// `reasoning_content`, `refusal`, provider extras — and the API requires the
/// assistant turn back verbatim before a tool reply may follow it.
struct Message: Decodable {
    let role: String?
    let content: Content?
    let toolCalls: [ToolCall]
    let raw: JSONValue

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        raw = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decode(String.self, forKey: .role)
        content = try? container.decode(Content.self, forKey: .content)
        toolCalls = (try? container.decode([ToolCall].self, forKey: .toolCalls)) ?? []
    }

    var text: String {
        (content?.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChatCompletion: Decodable {
    let choices: [Choice]
    let raw: JSONValue

    struct Choice: Decodable {
        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    enum CodingKeys: String, CodingKey { case choices }

    init(from decoder: Decoder) throws {
        raw = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = (try? container.decode([Choice].self, forKey: .choices)) ?? []
    }

    /// True when the response carries either text or a tool call to act on.
    ///
    /// A tool turn legitimately returns `content: null`, so requiring text would
    /// reject a perfectly good response.
    var isUsable: Bool {
        guard let message = choices.first?.message else { return false }
        return !message.text.isEmpty || !message.toolCalls.isEmpty
    }

    /// The assistant text, or throw with enough detail to debug.
    func text() throws -> String {
        guard let choice = choices.first else {
            throw ReviewFailure(message: "Unexpected CommandCode response: \(raw.preview())")
        }
        let value = choice.message?.text ?? ""
        if value.isEmpty {
            throw ReviewFailure(
                message: "Empty completion (finish_reason="
                    + "\(choice.finishReason ?? "nil")): \(raw.preview(300))")
        }
        return value
    }
}

/// A finding as the model emitted it. Untrusted: fields go missing and `line`
/// arrives as a number or a numeric string depending on the model, so every field
/// is decoded leniently rather than failing the whole review.
struct Finding: Decodable {
    let path: String
    let line: Int
    let severity: String
    let skill: String?
    let title: String?
    let detail: String?
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case path, line, severity, skill, title, detail, suggestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = Self.text(container, .path) ?? ""
        let rawSeverity = Self.text(container, .severity) ?? ""
        severity = rawSeverity.isEmpty ? "medium" : rawSeverity.lowercased()
        skill = Self.text(container, .skill)
        title = Self.text(container, .title)
        detail = Self.text(container, .detail)
        suggestion = Self.text(container, .suggestion)

        if let number = try? container.decode(Int.self, forKey: .line) {
            line = number
        } else if let text = Self.text(container, .line), let number = Int(text) {
            line = number
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .line, in: container, debugDescription: "no usable line number")
        }
    }

    private static func text(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys)
        -> String?
    {
        guard let value = try? container.decode(String.self, forKey: key) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decodes to nil rather than failing the whole array when one element is bad.
///
/// `[Finding]` is all-or-nothing: one malformed finding would throw and discard
/// the entire review. The original skipped bad findings individually and so must
/// this.
struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws { value = try? Wrapped(from: decoder) }
}

struct Review: Decodable {
    let summary: String
    let risk: String
    let riskReason: String
    let findings: [Finding]
    /// Whether the model actually emitted a `findings` key. `isFinalReview` needs
    /// the difference between "no findings" and "not a review at all".
    let hasFindingsKey: Bool

    enum CodingKeys: String, CodingKey {
        case summary, risk, findings
        case riskReason = "risk_reason"
    }

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        hasFindingsKey = raw["findings"] != nil

        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = ((try? container.decode(String.self, forKey: .summary)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawRisk = ((try? container.decode(String.self, forKey: .risk)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        risk = rawRisk.isEmpty ? "low" : rawRisk
        riskReason = ((try? container.decode(String.self, forKey: .riskReason)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        findings = ((try? container.decode([Lossy<Finding>].self, forKey: .findings)) ?? [])
            .compactMap(\.value)
    }
}

struct ModelInfo: Decodable {
    let id: String?
    let supportedEndpoints: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case supportedEndpoints = "supported_endpoints"
    }

    /// A missing or empty endpoint list means "assume it works", matching the
    /// original. Claude models list `/messages` only and must be filtered out.
    var servesChat: Bool {
        guard let endpoints = supportedEndpoints, !endpoints.isEmpty else { return true }
        return endpoints.contains(chatEndpoint)
    }
}

// MARK: - Outgoing payloads

struct ChatRequest: Encodable {
    let model: String
    let messages: [JSONValue]
    var temperature: Double?
    var responseFormat: ResponseFormat?
    var tools: [Tool]?

    struct ResponseFormat: Encodable { let type: String }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, tools
        case responseFormat = "response_format"
    }
}

/// The one tool the reviewer may call: read a skill's full rules.
struct Tool: Encodable {
    let type: String
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters
    }

    struct Parameters: Encodable {
        let type: String
        let properties: [String: Property]
        let required: [String]
    }

    struct Property: Encodable {
        let type: String
        let description: String
        var allowedValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type, description
            case allowedValues = "enum"
        }
    }
}

struct ReviewSubmission: Encodable {
    let commitId: String
    let body: String
    let event: String
    let comments: [InlineComment]

    enum CodingKeys: String, CodingKey {
        case body, event, comments
        case commitId = "commit_id"
    }
}

struct InlineComment: Encodable {
    let path: String
    let line: Int
    let side: String
    let body: String
}

// MARK: - Small helpers

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func jsonString(_ object: [String: JSONValue]) -> String {
    JSONValue.object(object).preview(Int.max)
}

/// Python's `str.capitalize()`: first letter upper, the rest lower. Swift's
/// `.capitalized` title-cases every word, which is not the same thing.
func pythonCapitalize(_ text: String) -> String {
    guard let first = text.first else { return text }
    return String(first).uppercased() + text.dropFirst().lowercased()
}

func joinedOrNone(_ items: [String]) -> String {
    items.isEmpty ? "none" : items.joined(separator: ", ")
}

extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return firstMatch(in: text, range: range) != nil
    }
}

// MARK: - HTTP

struct HTTPResult {
    let status: Int
    let body: Data
}

/// Blocking request. URLSession is async, so a semaphore bridges it back to the
/// straight-line flow the rest of the script is written in.
func performRequest(
    _ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval
) throws -> HTTPResult {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = body

    final class Box {
        var result: HTTPResult?
        var failure: Error?
    }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error = error {
            box.failure = error
            return
        }
        guard let http = response as? HTTPURLResponse else {
            box.failure = ReviewFailure(message: "no HTTP response")
            return
        }
        box.result = HTTPResult(status: http.statusCode, body: data ?? Data())
    }
    task.resume()
    semaphore.wait()

    if let failure = box.failure { throw failure }
    guard let result = box.result else { throw ReviewFailure(message: "empty response") }
    return result
}

/// Short reason from the CommandCode error envelope, for the log line.
func errorNote(from body: Data) -> String {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
        let error = value["error"]?.object
    else { return "" }
    let message = error["message"]?.string ?? error["type"]?.string ?? ""
    if let code = error["code"]?.string, !code.isEmpty {
        return "\(code): \(message)"
    }
    return message
}

func postCommandcode(_ payload: ChatRequest, apiKey: String) throws -> ChatCompletion {
    let data = try JSONEncoder().encode(payload)
    let result = try performRequest(
        URL(string: apiURL)!,
        method: "POST",
        headers: [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
        ],
        body: data,
        timeout: 120
    )
    if result.status >= 400 {
        throw HTTPFailure(code: result.status, note: errorNote(from: result.body))
    }
    do {
        return try JSONDecoder().decode(ChatCompletion.self, from: result.body)
    } catch {
        throw ReviewFailure(message: "CommandCode returned unreadable JSON")
    }
}

/// Model objects from /provider/v1/models, each with supported_endpoints.
func listCommandcodeModels(apiKey: String) throws -> [ModelInfo] {
    let result = try performRequest(
        URL(string: modelsURL)!,
        method: "GET",
        headers: ["Authorization": "Bearer \(apiKey)", "User-Agent": userAgent],
        body: nil,
        timeout: 30
    )
    if result.status >= 400 {
        throw HTTPFailure(code: result.status, note: errorNote(from: result.body))
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: result.body),
        let entries = value["data"],
        let data = try? JSONEncoder().encode(entries)
    else { return [] }
    return (try? JSONDecoder().decode([ModelInfo].self, from: data)) ?? []
}

// MARK: - Skills

struct Skill {
    let name: String
    let description: String
    let body: String
}

/// Split an Agent-Skill file into (frontmatter metadata, body).
func parseSkillFile(_ text: String) -> (meta: [String: String], body: String) {
    var meta: [String: String] = [:]
    var body = text
    if text.hasPrefix("---") {
        let searchStart = text.index(text.startIndex, offsetBy: 3)
        if let end = text.range(of: "\n---", range: searchStart..<text.endIndex) {
            for line in text[searchStart..<end.lowerBound].split(
                separator: "\n", omittingEmptySubsequences: false)
            {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                meta[key] = value
            }
            body = String(text[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return (meta, body)
}

/// Load every skillsDir/<skill>/SKILL.md as a Skill.
func loadSkillFiles(_ directory: String) -> [Skill] {
    var skills: [Skill] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return skills
    }
    for entry in entries.sorted() {
        let path = "\(directory)/\(entry)/SKILL.md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let (meta, body) = parseSkillFile(text)
        skills.append(
            Skill(name: meta["name"] ?? entry, description: meta["description"] ?? "", body: body))
    }
    return skills
}

/// The system-prompt skill index: names and descriptions, bodies NOT loaded.
///
/// This is level 1 of progressive disclosure — always present, ~100 tokens per
/// skill, and the only thing that tells the model a skill exists. Strip it and
/// `load_skill` becomes unreachable.
func buildCatalogue(_ skills: [Skill]) -> String {
    var lines = [
        "## Available review skills",
        "",
        "Each skill below states the conditions that make it relevant. The rules themselves are "
            + "not loaded — call `load_skill` to read one before reporting a finding that depends "
            + "on it.",
        "",
    ]
    for skill in skills {
        lines.append(
            "- **\(skill.name)**: \(skill.description.isEmpty ? skill.name : skill.description)")
    }
    return lines.joined(separator: "\n")
}

func skillTool(_ skillNames: [String]) -> Tool {
    Tool(
        type: "function",
        function: Tool.Function(
            name: "load_skill",
            description: "Read the full rules for one review skill. The system prompt lists every "
                + "skill with the conditions that make it relevant. Call this before reporting any "
                + "finding that depends on a skill's rules, and call it again for a second skill if "
                + "you need one. If no skill applies to this diff, do not call it at all.",
            parameters: Tool.Parameters(
                type: "object",
                properties: [
                    "name": Tool.Property(
                        type: "string",
                        description: "Which skill's rules to read.",
                        allowedValues: skillNames.sorted())
                ],
                required: ["name"]
            )
        )
    )
}

// MARK: - The tool loop

/// Run the reviewer as a tool loop so it pulls skill bodies itself.
///
/// This is the same shape Claude Code and Codex use: the catalogue of names and
/// descriptions sits in the system prompt, the model reads the diff, and it asks
/// for a body only when one is relevant.
func reviewWithSkills(
    system: String, user: String, model: String, apiKey: String, bodies: [String: String]
) throws -> (text: String, loaded: [String], model: String) {
    let tools = [skillTool(Array(bodies.keys))]
    var messages: [JSONValue] = [
        .message(role: "system", content: system),
        .message(role: "user", content: user),
    ]
    var loaded: [String] = []

    for _ in 0..<maxToolTurns {
        let (completion, servedBy) = try complete(messages, model, apiKey, tools: tools)
        guard let message = completion.choices.first?.message else {
            return (try completion.text(), loaded, servedBy)
        }

        if message.toolCalls.isEmpty {
            return (try completion.text(), loaded, servedBy)
        }
        // Answer and tool call in one turn: take the answer, skip the round trip.
        if isFinalReview(completion) {
            return (try completion.text(), loaded, servedBy)
        }

        // The assistant turn must go back verbatim, tool_calls included, or the
        // tool replies that follow are orphaned and the API rejects the request.
        messages.append(message.raw)

        for (index, call) in message.toolCalls.enumerated() {
            let name = call.skillName ?? ""
            let body: String
            if !name.isEmpty, loaded.contains(name) {
                body = "[\(name) is already loaded above. Do not ask for it again.]"
            } else if let real = bodies[name] {
                loaded.append(name)
                body = "=== SKILL: \(name) ===\n\(real)"
            } else {
                // The recovery path a separate router cannot offer: the model is
                // told what does exist and may retry.
                body =
                    "[No skill named '\(name)'. Available: "
                    + "\(bodies.keys.sorted().joined(separator: ", ")). "
                    + "Retry with one of those, or continue without it.]"
            }
            // The API rejects a tool reply with no id, so synthesise one rather
            // than dropping the call.
            let id = call.id.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
            messages.append(.toolMessage(id: id, content: body))
        }

        print("::notice::Skills loaded so far: \(loaded)")
    }

    // Out of turns: drop the tools so the model has to answer.
    print("::warning::Tool loop hit MAX_TOOL_TURNS=\(maxToolTurns); forcing an answer")
    messages.append(.message(role: "user", content: "Return the JSON review now."))
    let (completion, servedBy) = try complete(messages, model, apiKey)
    do {
        return (try completion.text(), loaded, servedBy)
    } catch {
        // A model that still answers with a tool call has nothing to say. Return a
        // valid, honest review rather than throwing, so the PR gets a comment
        // explaining what happened instead of a generic "unavailable".
        return (
            jsonString([
                "summary": .string(
                    "The reviewer kept requesting skills and produced no review within "
                        + "\(maxToolTurns) turns. Skills loaded: \(joinedOrNone(loaded))."),
                "risk": .string("low"),
                "risk_reason": .string("no review was produced"),
                "findings": .array([]),
            ]),
            loaded,
            servedBy
        )
    }
}

/// True when the response already holds the review JSON.
///
/// Some models emit the answer and a tool call in the same turn. Taking the answer
/// avoids a whole extra turn, and a turn re-sends the entire diff. Strict on
/// purpose: the parsed object must actually have a `findings` key.
func isFinalReview(_ completion: ChatCompletion) -> Bool {
    guard let text = try? completion.text() else { return false }
    return decodeReview(text)?.hasFindingsKey == true
}

/// Warn when a finding cites a skill the model never loaded.
///
/// Under the pull design a citation is a claim that the model read that skill's
/// rules. A citation for something it never asked for is fabricated, and this is
/// the only place it can be detected — a router could not tell you whether its own
/// pick was right.
func checkCitations(_ review: Review?, _ loaded: [String]) {
    guard let review = review else { return }
    let cited = Set(review.findings.compactMap { $0.skill }.filter { !$0.isEmpty })
    let ghosts = cited.subtracting(Set(loaded)).sorted()
    if !ghosts.isEmpty {
        print(
            "::warning::Findings cite skills that were never loaded: \(ghosts). "
                + "Loaded: \(joinedOrNone(loaded))")
    }
}

// MARK: - Diff handling

/// Drop binary/lock/generated hunks so tokens go to real Swift changes.
func filterDiff(_ diff: String) -> String {
    var kept: [String] = []
    var currentPath = ""
    var skipCurrent = false
    for line in diff.components(separatedBy: "\n") {
        if line.hasPrefix("diff --git") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " b/")
            currentPath = parts.count > 1 ? parts[parts.count - 1] : ""
            skipCurrent =
                skipPrefixes.contains { currentPath.hasPrefix($0) }
                || skipSuffixes.contains { currentPath.hasSuffix($0) }
            if !skipCurrent { kept.append(line) }
        } else if !skipCurrent {
            kept.append(line)
        }
    }
    return kept.joined(separator: "\n")
}

func truncate(_ text: String, _ limit: Int) -> (text: String, wasTruncated: Bool) {
    if text.count <= limit { return (text, false) }
    let head = String(text.prefix(limit))
    if let cut = head.range(of: "\n", options: .backwards), cut.lowerBound > head.startIndex {
        return (String(head[head.startIndex..<cut.lowerBound]), true)
    }
    return (head, true)
}

/// Map each file path to the NEW-side line numbers present in the diff hunks.
///
/// Only lines inside hunks (added `+` or context ` ` lines) are valid anchors for
/// the Reviews API. Returns [:] for files with no hunks.
func parseDiffHunks(_ diff: String) -> [String: Set<Int>] {
    var hunks: [String: Set<Int>] = [:]
    let hunkHeader = try! NSRegularExpression(pattern: "\\+(\\d+)(?:,(\\d+))?")
    var path = ""
    var newLine = 0
    var inHunk = false

    for raw in diff.components(separatedBy: "\n") {
        if raw.hasPrefix("diff --git") {
            let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " b/")
            path = parts.count > 1 ? parts[parts.count - 1] : ""
            inHunk = false
            continue
        }
        if raw.hasPrefix("@@") {
            let ns = raw as NSString
            if let match = hunkHeader.firstMatch(
                in: raw, range: NSRange(location: 0, length: ns.length))
            {
                newLine = Int(ns.substring(with: match.range(at: 1))) ?? 0
                inHunk = !path.isEmpty
                if inHunk { hunks[path] = hunks[path] ?? [] }
            } else {
                newLine = 0
                inHunk = false
            }
            continue
        }
        if !inHunk || path.isEmpty { continue }
        if raw.hasPrefix("+++") || raw.hasPrefix("---") { continue }
        if raw.hasPrefix("+") {
            hunks[path, default: []].insert(newLine)
            newLine += 1
        } else if raw.hasPrefix("-") {
            continue  // old side: not a valid anchor
        } else {
            hunks[path, default: []].insert(newLine)
            newLine += 1
        }
    }
    return hunks
}

// MARK: - Model selection

/// Ordered fallback model IDs that can actually serve /chat/completions.
///
/// Claude models are /messages-only, so sending one here is a hard 400 — they are
/// filtered out via supported_endpoints. Same-family siblings rank first (best
/// substitute for a retired flash), then everything else.
func candidateModels(_ models: [ModelInfo], preferred: String) -> [String] {
    let ids = models.compactMap { entry -> String? in
        guard let id = entry.id, !id.isEmpty, entry.servesChat, !noiseRegex.matches(id) else {
            return nil
        }
        return id
    }

    var ordered: [String] = ids.contains(preferred) ? [preferred] : []
    let family =
        preferred.contains("/")
        ? String(preferred.split(separator: "/")[0]) + "/" : ""
    let siblings = ids.filter { !family.isEmpty && $0.hasPrefix(family) && !ordered.contains($0) }
    ordered.append(contentsOf: siblings.filter { !prereleaseRegex.matches($0) }.sorted())
    ordered.append(contentsOf: siblings.filter { prereleaseRegex.matches($0) }.sorted())
    ordered.append(contentsOf: ids.filter { !ordered.contains($0) }.sorted())
    return Array(ordered.prefix(maxModelsTried))
}

// MARK: - Completion

/// OpenAI Chat Completions body. `minimal` drops the optional knobs.
///
/// No max_tokens on purpose: `deepseek-v4.1-flash` is a reasoning model, so a cap
/// is shared between reasoning_content and the answer. A 4096 cap was consumed
/// entirely by reasoning on a real diff, returning finish_reason 'length' with
/// empty content. The provider default is sized for this.
///
/// temperature is undocumented by CommandCode but accepted. A model that rejects
/// it gets one retry with just model + messages, and the latch turns off so later
/// calls in the same run don't pay for the same discovery twice.
///
/// `response_format: json_object` is deliberately NOT set when tools are present.
/// A tool turn has to be free to answer with `tool_calls` and no content, which a
/// strict JSON response format forbids.
func buildRequest(
    model: String, messages: [JSONValue], minimal: Bool = false, tools: [Tool]? = nil
) -> ChatRequest {
    var request = ChatRequest(model: model, messages: messages)
    if !minimal && latches.optionalParamsOK {
        request.temperature = 0.2
        if tools == nil || tools!.isEmpty {
            request.responseFormat = ChatRequest.ResponseFormat(type: "json_object")
        }
    }
    if let tools = tools, !tools.isEmpty {
        request.tools = tools
    }
    return request
}

/// Post a message list and return (completion, model_used).
///
/// Walks up to 4 models on 400/404/429/5xx, the same resilience the single-shot
/// path had. Throws ToolsUnsupported when the refusal is about `tools`, so the
/// caller can inline every skill body instead of losing the review.
func complete(
    _ messages: [JSONValue], _ model: String, _ apiKey: String, tools: [Tool]? = nil
) throws -> (completion: ChatCompletion, model: String) {
    if let tools = tools, !tools.isEmpty, !latches.toolsOK {
        throw ToolsUnsupported(note: "tools already refused earlier in this run")
    }

    var candidates = [model]
    var tried = Set<String>()
    var discovered = false
    var lastError: Error?
    var index = 0

    while index < candidates.count {
        let name = candidates[index]
        index += 1
        if tried.contains(name) { continue }
        tried.insert(name)

        for minimal in [false, true] {
            do {
                let completion = try postCommandcode(
                    buildRequest(model: name, messages: messages, minimal: minimal, tools: tools),
                    apiKey: apiKey
                )
                if !completion.isUsable {
                    throw ReviewFailure(message: "Empty completion: \(completion.raw.preview(300))")
                }
                return (completion, name)
            } catch let exc as HTTPFailure {
                lastError = exc
                if let tools = tools, !tools.isEmpty, exc.code == 400,
                    exc.note.lowercased().contains("tool")
                {
                    latches.toolsOK = false
                    throw ToolsUnsupported(note: exc.note)
                }
                if exc.code == 400 && !minimal {
                    latches.optionalParamsOK = false
                    print(
                        "::warning::'\(name)' rejected optional params, retrying minimal: \(exc.note)"
                    )
                    continue
                }
                print("::warning::Model '\(name)' failed: HTTP \(exc.code) \(exc.note)")
                if !fallthroughStatus.contains(exc.code) && exc.code < 500 {
                    throw exc  // 401/403: key or plan problem, another model won't help
                }
                if exc.code == 429 {
                    Thread.sleep(forTimeInterval: 15)
                }
            } catch let exc as ToolsUnsupported {
                throw exc
            } catch let exc {  // timeout, empty completion, bad JSON
                lastError = exc
                print("::warning::Model '\(name)' failed: \(exc)")
            }
        }

        if !discovered {
            discovered = true
            do {
                let models = try listCommandcodeModels(apiKey: apiKey)
                candidates.append(contentsOf: candidateModels(models, preferred: model))
                print("::notice::Model candidates: \(candidates)")
            } catch {
                print("::warning::Model discovery failed: \(error)")
            }
        }
        if tried.count >= maxModelsTried { break }
    }
    throw lastError ?? ReviewFailure(message: "No CommandCode model available")
}

/// Single-shot completion. Returns (review_text, model_used).
func callCommandcode(
    system: String, user: String, model: String, apiKey: String
) throws -> (text: String, model: String) {
    let messages: [JSONValue] = [
        .message(role: "system", content: system),
        .message(role: "user", content: user),
    ]
    let (completion, used) = try complete(messages, model, apiKey)
    return (try completion.text(), used)
}

// MARK: - Review building

/// The JSON object inside the model's reply, tolerating ```json fences or prose.
func extractJSONText(_ text: String) -> String? {
    let pattern = "```(?:json)?\\s*(\\{.*?\\})\\s*```"
    guard
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    else { return nil }
    let ns = text as NSString

    if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
        match.numberOfRanges > 1
    {
        return ns.substring(with: match.range(at: 1))
    }
    if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end {
        return String(text[start...end])
    }
    return nil
}

/// Decode the model's review, or nil when there is no usable JSON object.
func decodeReview(_ text: String) -> Review? {
    guard let json = extractJSONText(text) else { return nil }
    return try? JSONDecoder().decode(Review.self, from: Data(json.utf8))
}

/// Build (review_body, inline_comments, used_fallback).
///
/// Inline comments anchor to diff lines for the Files-tab threads with one-click
/// suggestions. Findings pointing outside the diff fall back into the body as
/// general notes. Non-JSON model output sets used_fallback so the caller can post
/// it as a plain comment instead.
func buildReview(_ modelText: String, _ hunks: [String: Set<Int>], maxInline: Int = 8)
    -> (body: String, comments: [InlineComment], usedFallback: Bool)
{
    guard let review = decodeReview(modelText) else {
        return (modelText.trimmingCharacters(in: .whitespacesAndNewlines), [], true)
    }

    var comments: [InlineComment] = []
    var general: [String] = []

    for finding in review.findings {
        let emoji = severityEmoji[finding.severity] ?? "🟡"
        var label = "**\(emoji) \(pythonCapitalize(finding.severity))**"
        if let skill = finding.skill, !skill.isEmpty { label += " `[\(skill)]`" }
        if let title = finding.title, !title.isEmpty { label += " — \(title)" }
        let detail = finding.detail ?? ""

        if hunks[finding.path]?.contains(finding.line) == true && comments.count < maxInline {
            var body = detail.isEmpty ? label : "\(label)\n\n\(detail)"
            if let suggestion = finding.suggestion, !suggestion.isEmpty {
                body += "\n\n```suggestion\n\(suggestion)\n```"
            }
            comments.append(
                InlineComment(path: finding.path, line: finding.line, side: "RIGHT", body: body))
        } else {
            let location = finding.path.isEmpty ? "general" : "\(finding.path):~\(finding.line)"
            var item = "- \(label) \(location)"
            if !detail.isEmpty { item += " — \(detail)" }
            general.append(item)
        }
    }

    var summary = review.summary
    if summary.isEmpty && review.findings.isEmpty {
        summary = "No significant issues found."
    }
    var body = "### Summary\n\(summary)\n\n### Risk\n\(review.risk)"
    if !review.riskReason.isEmpty { body += " — \(review.riskReason)" }
    body += "\n"
    if !general.isEmpty {
        body +=
            "\n### General notes (outside the changed lines)\n"
            + general.joined(separator: "\n") + "\n"
    }
    if review.findings.isEmpty {
        body += "\nNo significant issues found.\n"
    }
    return (body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", comments, false)
}

// MARK: - Posting

/// Fallback: plain Conversation comment via gh (no inline anchoring).
func postComment(prNumber: String, repo: String, bodyFile: String) throws {
    let process = Process()
    // /usr/bin/env so PATH lookup works; Process does not resolve bare names.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "pr", "comment", prNumber, "--repo", repo, "--body-file", bodyFile]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw ReviewFailure(message: "gh pr comment exited \(process.terminationStatus)")
    }
}

/// Submit a real PR review: inline threads + suggestion blocks, event COMMENT.
func submitReview(
    repo: String, prNumber: String, commit: String, body: String, comments: [InlineComment],
    token: String
) throws {
    let payload = ReviewSubmission(
        commitId: commit,
        body: body,
        event: "COMMENT",  // advisory: never approves, never requests changes
        comments: comments
    )
    let data = try JSONEncoder().encode(payload)
    let result = try performRequest(
        URL(string: "https://api.github.com/repos/\(repo)/pulls/\(prNumber)/reviews")!,
        method: "POST",
        headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        ],
        body: data,
        timeout: 60
    )
    if result.status >= 400 {
        throw HTTPFailure(
            code: result.status, note: String(data: result.body, encoding: .utf8) ?? "")
    }
    if let value = try? JSONDecoder().decode(JSONValue.self, from: result.body) {
        print(
            "Submitted review id \(value["id"]?.preview(40) ?? "nil") "
                + "with \(comments.count) inline comments")
    }
}

// MARK: - Arguments

struct Arguments {
    var diff = ""
    var prNumber = "0"
    var repo = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? "local/test"
    var title = ProcessInfo.processInfo.environment["PR_TITLE"] ?? ""
    var body = ProcessInfo.processInfo.environment["PR_BODY"] ?? ""
    var skillsDir = ".github/skills"
    var systemPrompt = ".github/prompts/reviewer-system.md"
    var model = ProcessInfo.processInfo.environment["COMMANDCODE_MODEL"] ?? defaultModel
    var maxDiffChars = 100_000
    var maxInline = 8
    var commit = ProcessInfo.processInfo.environment["PR_HEAD_SHA"] ?? ""
    var output = "review.md"
    var post = true
}

func parseArguments() -> Arguments {
    var args = Arguments()
    let argv = Array(CommandLine.arguments.dropFirst())
    var index = 0

    func value(for flag: String) -> String {
        index += 1
        guard index < argv.count else {
            warn("::warning::\(flag) needs a value")
            return ""
        }
        return argv[index]
    }

    while index < argv.count {
        let flag = argv[index]
        switch flag {
        case "--diff": args.diff = value(for: flag)
        case "--pr-number": args.prNumber = value(for: flag)
        case "--repo": args.repo = value(for: flag)
        case "--title": args.title = value(for: flag)
        case "--body": args.body = value(for: flag)
        case "--skills-dir": args.skillsDir = value(for: flag)
        case "--system-prompt": args.systemPrompt = value(for: flag)
        case "--model": args.model = value(for: flag)
        case "--max-diff-chars": args.maxDiffChars = Int(value(for: flag)) ?? args.maxDiffChars
        case "--max-inline": args.maxInline = Int(value(for: flag)) ?? args.maxInline
        case "--commit": args.commit = value(for: flag)
        case "--output": args.output = value(for: flag)
        case "--post": args.post = true
        case "--no-post": args.post = false
        default: warn("::warning::Unknown argument \(flag)")
        }
        index += 1
    }
    return args
}

// MARK: - Entry point

func main() throws -> Int32 {
    let args = parseArguments()

    let systemBase =
        (try? String(contentsOfFile: args.systemPrompt, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let skillFiles = loadSkillFiles(args.skillsDir)
    var skillNames: [String] = []

    let rawDiff = (try? String(contentsOfFile: args.diff, encoding: .utf8)) ?? ""
    var modelUsed = args.model
    var body = ""
    var comments: [InlineComment] = []
    var usedFallback = false  // true: non-JSON output, post as plain comment instead

    if rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        body = "### Summary\nEmpty diff.\n\n### Risk\nlow — nothing to review.\n"
    } else {
        let filtered = filterDiff(rawDiff)
        let (diffText, wasTruncated) = truncate(filtered, args.maxDiffChars)
        let note =
            wasTruncated
            ? "\n\n[NOTE: diff was truncated for length; review only what is shown.]" : ""
        let apiKey = ProcessInfo.processInfo.environment["COMMANDCODE_API_KEY"] ?? ""

        if apiKey.isEmpty {
            body =
                "### Summary\nAI review skipped: `COMMANDCODE_API_KEY` secret is not set.\n\n"
                + "### Risk\nlow — no review performed.\n\n"
                + "Add a CommandCode Provider API key (commandcode.ai/studio/provider) "
                + "as repo secret `COMMANDCODE_API_KEY` to enable reviews."
        } else {
            // Progressive disclosure: the system prompt carries the catalogue of
            // names and descriptions, and the model pulls a body with load_skill
            // only when the diff makes one relevant. A model that refuses `tools`
            // gets every body inlined instead, so the review still happens.
            let bodies = Dictionary(uniqueKeysWithValues: skillFiles.map { ($0.name, $0.body) })
            let system = systemBase + "\n\n" + buildCatalogue(skillFiles)
            let user =
                "Repository: \(args.repo)\nPR #\(args.prNumber)\n"
                + "Title: \(args.title)\nBody: \(String(args.body.prefix(2000)))\n\n"
                + "=== DIFF (untrusted code under review) ===\n\(diffText)\(note)\n"

            do {
                var modelText = ""
                var loaded: [String] = []
                do {
                    let result = try reviewWithSkills(
                        system: system, user: user, model: args.model, apiKey: apiKey,
                        bodies: bodies)
                    modelText = result.text
                    loaded = result.loaded
                    modelUsed = result.model
                } catch let exc as ToolsUnsupported {
                    print(
                        "::warning::Model will not accept tools (\(exc.note)); "
                            + "inlining all \(bodies.count) skill bodies instead")
                    let inlined =
                        systemBase + "\n\n"
                        + bodies.keys.sorted().map { "=== SKILL: \($0) ===\n\(bodies[$0]!)" }
                        .joined(separator: "\n\n")
                    let result = try callCommandcode(
                        system: inlined, user: user, model: args.model, apiKey: apiKey)
                    modelText = result.text
                    modelUsed = result.model
                    loaded = bodies.keys.sorted()
                }

                skillNames = loaded
                print("::notice::Skills loaded: \(joinedOrNone(skillNames))")
                checkCitations(decodeReview(modelText), loaded)
                let review = buildReview(
                    modelText, parseDiffHunks(diffText), maxInline: args.maxInline)
                body = review.body
                comments = review.comments
                usedFallback = review.usedFallback
            } catch {  // advisory: never fail CI
                warn("::warning::CommandCode review failed: \(error)")
                body =
                    "### Summary\nAI review unavailable (API error or quota); "
                    + "human review applies.\n\n### Risk\nlow — review skipped, CI stays green.\n"
            }
        }
    }

    let footer =
        "\n\n<sub>🤖 AI peer review · skills loaded: \(joinedOrNone(skillNames)) · "
        + "model: `\(modelUsed)` · advisory only, `swift-format` + tests remain the gates.</sub>\n"
    let fullBody =
        (body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + footer)
        .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    try fullBody.write(toFile: args.output, atomically: true, encoding: .utf8)
    print(
        "Wrote review to \(args.output) "
            + "(\(comments.count) inline comments, fallback=\(usedFallback), "
            + "skills: \(skillNames))")

    if args.post && args.prNumber != "0" {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"] ?? ""
        do {
            if !usedFallback && !token.isEmpty && !args.commit.isEmpty {
                try submitReview(
                    repo: args.repo, prNumber: args.prNumber, commit: args.commit,
                    body: fullBody, comments: comments, token: token)
                print("Submitted PR review on #\(args.prNumber)")
            } else {
                if !usedFallback {
                    print("::notice::No token/commit for Reviews API; plain comment fallback")
                }
                try postComment(prNumber: args.prNumber, repo: args.repo, bodyFile: args.output)
                print("Posted plain comment to PR #\(args.prNumber)")
            }
        } catch {
            warn("::warning::Could not post review: \(error)")
        }
    }
    return 0
}

do {
    exit(try main())
} catch {
    warn("::warning::ai_review.swift failed: \(error)")
    exit(0)
}
