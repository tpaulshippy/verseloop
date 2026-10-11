import Foundation

enum ESVError: LocalizedError {
    case badReference
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badReference: return "That reference didn't return ESV text. Try e.g. “John 1:1” or “Ps 23:1-2”."
        case .server(let s): return "ESV fetch failed: \(s)"
        }
    }
}

struct WorkerESVResponse: Decodable {
    let text: String?
    let error: String?
}

/// Fetches ESV text at runtime through your own Cloudflare Worker proxy
/// (which holds the api.esv.org key server-side) — never bundled
/// (Crossway ©, All rights reserved), never keyed on-device.
struct ESVService {
    var workerBaseURL: String

    func fetchPassage(_ reference: String) async throws -> String {
        let q = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ESVError.badReference }
        let b = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = b.hasSuffix("/") ? String(b.dropLast()) : b
        guard let eq = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/v1/esv?q=\(eq)") else { throw ESVError.badReference }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ESVError.server("server HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let decoded = try? JSONDecoder().decode(WorkerESVResponse.self, from: data),
              let t = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw ESVError.server("empty passage")
        }
        return t
    }

    static let attribution = "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved."
}
