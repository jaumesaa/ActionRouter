import CryptoKit
import Foundation
import os

/// Where action-metadata embeddings are cached between launches.
///
/// Only *document* (action metadata) embeddings are ever cached; user
/// queries are never written to memory caches beyond the call or to disk.
public enum EmbeddingDiskCachePolicy: Sendable, Equatable {
    /// In-memory for the session only.
    case disabled
    /// Persist under the user Caches directory
    /// (`Caches/ActionRouter/embeddings-<provider>.json`). Safe in
    /// sandboxed apps; the system may purge it, which only costs a
    /// re-embed. This is the default.
    case automatic
    /// Persist inside the given directory (created if needed).
    case directory(URL)
}

/// Content-addressed cache of document embeddings for one provider.
/// Keys are SHA-256 digests of the embedded text, so no action text is
/// stored on disk. Confined to the router actor; not thread-safe on its own.
final class EmbeddingVectorCache {
    private struct FilePayload: Codable {
        var version: Int
        /// digest -> little-endian Float32 bytes, base64.
        var entries: [String: String]
    }

    private let providerID: String
    private let fileURL: URL?
    private let logger = Logger(subsystem: "dev.actionrouter", category: "cache")

    private var entries: [String: [Float]] = [:]
    private var usedKeys: Set<String> = []
    private var loaded = false
    private var dirty = false

    /// Entries beyond this are dropped at save time (least-recently-loaded
    /// first, keeping everything used this session).
    private let capacity = 20_000

    init(providerID: String, policy: EmbeddingDiskCachePolicy) {
        self.providerID = providerID
        switch policy {
        case .disabled:
            self.fileURL = nil
        case .automatic:
            let base = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
            self.fileURL = base.map {
                $0.appendingPathComponent("ActionRouter", isDirectory: true)
                    .appendingPathComponent(Self.fileName(for: providerID))
            }
        case .directory(let directory):
            self.fileURL = directory.appendingPathComponent(
                Self.fileName(for: providerID)
            )
        }
    }

    private static func fileName(for providerID: String) -> String {
        let sanitized = providerID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "embeddings-\(String(sanitized)).json"
    }

    private static func key(purpose: EmbeddingPurpose, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(purpose.rawValue)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func vector(purpose: EmbeddingPurpose, text: String) -> [Float]? {
        loadIfNeeded()
        let key = Self.key(purpose: purpose, text: text)
        guard let vector = entries[key] else { return nil }
        usedKeys.insert(key)
        return vector
    }

    func store(_ vector: [Float], purpose: EmbeddingPurpose, text: String) {
        loadIfNeeded()
        let key = Self.key(purpose: purpose, text: text)
        entries[key] = vector
        usedKeys.insert(key)
        dirty = true
    }

    /// Writes the cache atomically if anything changed. Called by the
    /// router after registration batches.
    func persistIfNeeded() {
        guard dirty, let fileURL else { return }
        if entries.count > capacity {
            entries = entries.filter { usedKeys.contains($0.key) }
        }
        var payload = FilePayload(version: 1, entries: [:])
        payload.entries.reserveCapacity(entries.count)
        for (key, vector) in entries {
            payload.entries[key] = vector.withUnsafeBufferPointer {
                Data(buffer: $0).base64EncodedString()
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            logger.warning("Could not persist embedding cache: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(FilePayload.self, from: data),
              payload.version == 1 else { return }
        entries.reserveCapacity(payload.entries.count)
        for (key, base64) in payload.entries {
            guard let raw = Data(base64Encoded: base64),
                  raw.count % MemoryLayout<Float>.size == 0 else { continue }
            let vector = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            entries[key] = vector
        }
    }
}
