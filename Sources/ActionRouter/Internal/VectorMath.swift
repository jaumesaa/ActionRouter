import Accelerate

/// Small dense-vector helpers used by the semantic tier.
enum VectorMath {
    /// Returns the vector scaled to unit L2 norm, or `nil` for zero/empty
    /// vectors (which carry no directional information).
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm > .ulpOfOne else { return nil }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Dot product; equals cosine similarity for unit-normalized inputs.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}
