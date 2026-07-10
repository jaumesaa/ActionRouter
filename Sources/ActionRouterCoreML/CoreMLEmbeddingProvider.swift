import ActionRouter
import CoreML
import Foundation
import Tokenizers

/// Embedding provider that runs a converted Core ML sentence-embedding
/// model (see `tools/convert/convert_e5.py` for producing one from
/// `intfloat/multilingual-e5-small`).
///
/// Expectations on the model:
/// - single input `input_ids`, shape `[1, sequence]`, Int32, padded with
///   the model's pad token (the attention mask is derived in-model);
/// - output `embedding`, shape `[1, dimensions]`, already mean-pooled and
///   L2-normalized;
/// - an E5-style asymmetric scheme: texts are prefixed with `"query: "` or
///   `"passage: "` (disable with `usesE5Prefixes: false`).
///
/// The tokenizer directory must contain Hugging Face `tokenizer.json` and
/// `tokenizer_config.json` files matching the model.
public actor CoreMLEmbeddingProvider: EmbeddingProvider {
    public nonisolated let identifier: String

    private let modelURL: URL
    private let tokenizerDirectory: URL
    private let usesE5Prefixes: Bool
    private let maxSequenceLength: Int
    private let computeUnits: MLComputeUnits

    /// Sequence-length buckets matching the model's enumerated input shapes
    /// (fixed shapes keep the model eligible for the Neural Engine). Inputs
    /// are padded to the next bucket. XLM-R pad token id = 1.
    private let shapeBuckets = [32, 64, 128]
    private let padTokenID: Int32 = 1

    private var model: MLModel?
    private var tokenizer: (any Tokenizer)?

    public init(
        modelURL: URL,
        tokenizerDirectory: URL,
        identifier: String? = nil,
        usesE5Prefixes: Bool = true,
        maxSequenceLength: Int = 128,
        computeUnits: MLComputeUnits = .all
    ) {
        self.modelURL = modelURL
        self.tokenizerDirectory = tokenizerDirectory
        self.identifier = identifier
            ?? "coreml.\(modelURL.deletingPathExtension().lastPathComponent)"
        self.usesE5Prefixes = usesE5Prefixes
        self.maxSequenceLength = maxSequenceLength
        self.computeUnits = computeUnits
    }

    public func prepare() async throws {
        guard model == nil || tokenizer == nil else { return }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            // .mlpackage must be compiled before loading; cache the result
            // next to the caller-provided package so repeat launches skip it.
            let cached = modelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
            if FileManager.default.fileExists(atPath: cached.path) {
                compiledURL = cached
            } else {
                let temporary = try await MLModel.compileModel(at: modelURL)
                compiledURL = (try? FileManager.default.replaceItemAt(cached, withItemAt: temporary)) ?? temporary
            }
        }
        model = try await MLModel.load(contentsOf: compiledURL, configuration: configuration)
        tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
    }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        if model == nil || tokenizer == nil {
            try await prepare()
        }
        guard let model, let tokenizer else {
            throw EmbeddingError.unsupported("provider not prepared")
        }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            let prefixed = prefixedText(text, purpose: purpose)
            var ids = tokenizer.encode(text: prefixed)
            if ids.count > maxSequenceLength, let last = ids.last {
                // Keep the trailing special token (</s>) when truncating.
                ids = Array(ids.prefix(maxSequenceLength - 1)) + [last]
            }
            guard !ids.isEmpty else { throw EmbeddingError.emptyResult }

            let bucket = shapeBuckets.first { $0 >= ids.count } ?? maxSequenceLength
            let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: bucket)], dataType: .int32)
            for index in 0..<bucket {
                inputIDs[index] = NSNumber(value: index < ids.count ? Int32(ids[index]) : padTokenID)
            }

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIDs),
            ])
            let output = try predict(model, input)
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
                throw EmbeddingError.emptyResult
            }
            results.append(floatArray(from: embedding))
        }
        return results
    }

    /// Synchronous prediction in a non-async context, so the compiler picks
    /// the sync overload: the async variant would send the non-Sendable
    /// MLModel out of this actor. Blocking the provider actor for the
    /// compute-bound call is the intended behaviour.
    private func predict(
        _ model: MLModel, _ input: MLFeatureProvider
    ) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    private func prefixedText(_ text: String, purpose: EmbeddingPurpose) -> String {
        guard usesE5Prefixes else { return text }
        switch purpose {
        case .query: return "query: \(text)"
        case .document: return "passage: \(text)"
        }
    }

    private func floatArray(from multiArray: MLMultiArray) -> [Float] {
        // Per-index NSNumber access converts from any storage type
        // (FP16/FP32); at embedding sizes (384-1024 values) the cost is
        // negligible next to model prediction.
        let count = multiArray.count
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count { values[index] = multiArray[index].floatValue }
        return values
    }
}
