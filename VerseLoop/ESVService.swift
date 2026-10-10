import Foundation

enum ESVError: LocalizedError {
    case missingKey
    case badReference
    case server(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your free ESV API key in Settings (or set a Worker URL with the key server-side)."
        case .badReference: return "That reference didn't return ESV text. Try e.g. “John 1:1” or “Ps 23:1-2”."
        case .server(let s): return "ESV fetch failed: \(s)"
        case .decode: return "Couldn't read the ESV response."
        }
    }
}

struct ESVPassageResponse: Decodable {
    let passages: [String]?
    let detail: String?
}

struct WorkerESVResponse: Decodable {
    let text: String?
    let error: String?
}

/// Fetches ESV text at runtime — never bundled (Crossway ©, All rights reserved).
/// Prefers the Cloudflare Worker proxy (keeps the API key off-device + caches);
/// falls back to api.esv.org direct with the user's key from Settings.
struct ESVService {
    var workerBaseURL: String
    var apiKey: String

    func fetchPassage(_ reference: String) async throws -> String {
        let q = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ESVError.badReference }
        let base = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return try await fetchViaWorker(reference: q, base: base)
        }
        return try await fetchDirect(reference: q)
    }

    private func fetchViaWorker(reference: String, base: String) async throws -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let eq = reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(b)/v1/esv?q=\(eq)") else { throw ESVError.badReference }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ESVError.server("worker HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try JSONDecoder().decode(WorkerESVResponse.self, from: data)
        guard let t = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw ESVError.server(decoded.error ?? "empty passage")
        }
        return t
    }

    private func fetchDirect(reference: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ESVError.missingKey }
        var comps = URLComponents(string: "https://api.esv.org/v3/passage/text/")!
        comps.queryItems = [
            .init(name: "q", value: reference),
            .init(name: "include-footnotes", value: "false"),
            .init(name: "include-verse-numbers", value: "false"),
            .init(name: "include-short-copyright", value: "false"),
            .init(name: "include-passage-references", value: "false"),
            .init(name: "include-headings", value: "false"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ESVError.server("api.esv.org HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let decoded = try? JSONDecoder().decode(ESVPassageResponse.self, from: data) else {
            throw ESVError.decode
        }
        let text = (decoded.passages ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ESVError.badReference }
        return text
    }

    static let attribution = "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved."
}
