import CoreImage
import CoreGraphics
import Vision

/// Wraps Vision (feature print, aesthetics, face capture quality) plus Core Image's
/// CIDetector (smiles, eye blinks) into a single best-shot scorer.
enum Scorer {

    /// Perceptual fingerprint used to measure how similar two photos are.
    static func featurePrint(_ image: CGImage) async -> FeaturePrintObservation? {
        let request = GenerateImageFeaturePrintRequest()
        return try? await request.perform(on: image)
    }

    /// Distance between two feature prints. Lower = more similar. Returns .infinity on failure.
    static func distance(_ a: FeaturePrintObservation, _ b: FeaturePrintObservation) -> Double {
        (try? a.distance(to: b)) ?? .infinity
    }

    /// Full best-shot evaluation with an explanatory breakdown.
    static func bestShot(_ image: CGImage) async -> ScoreBreakdown {
        async let aesthetics = aestheticScore(image)
        async let quality = faceQuality(image)
        async let expression = faceExpression(image)

        let (aestheticN, isUtility) = await aesthetics
        let faceQuality = await quality
        let (faceCount, eyesOpen, smiling) = await expression

        var total: Double
        if faceCount > 0 {
            // People shots: prioritize open eyes and well-captured faces (Google's behavior),
            // give a modest boost for smiles, and keep aesthetics as a baseline.
            total = aestheticN * 0.35
                  + faceQuality * 0.30
                  + eyesOpen   * 0.25
                  + smiling    * 0.10
        } else {
            // Non-people shots: composition/exposure/sharpness is all we have.
            total = aestheticN
        }
        if isUtility { total -= 0.2 } // de-prioritize screenshots / documents

        return ScoreBreakdown(
            total: total,
            aesthetic: aestheticN,
            isUtility: isUtility,
            faceCount: faceCount,
            faceQuality: faceQuality,
            eyesOpen: eyesOpen,
            smiling: smiling
        )
    }

    // MARK: - Components

    /// Returns (normalized 0...1 aesthetic score, isUtility flag).
    private static func aestheticScore(_ image: CGImage) async -> (Double, Bool) {
        let request = CalculateImageAestheticsScoresRequest()
        guard let result = try? await request.perform(on: image) else { return (0.5, false) }
        let normalized = (Double(result.overallScore) + 1.0) / 2.0 // overallScore ≈ -1...1
        return (min(max(normalized, 0), 1), result.isUtility)
    }

    /// Max face capture quality across all detected faces (0 if no faces).
    private static func faceQuality(_ image: CGImage) async -> Double {
        let request = DetectFaceCaptureQualityRequest()
        guard let faces = try? await request.perform(on: image) else { return 0 }
        return faces.compactMap { $0.captureQuality.map { Double($0.score) } }.max() ?? 0
    }

    /// Uses Core Image's face detector for expression cues Vision doesn't expose.
    /// Returns (faceCount, fraction of faces with both eyes open, fraction smiling).
    private static func faceExpression(_ image: CGImage) async -> (Int, Double, Double) {
        let ci = CIImage(cgImage: image)
        let detector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ci, options: [
            CIDetectorSmile: true,
            CIDetectorEyeBlink: true
        ]) as? [CIFaceFeature] ?? []

        guard !features.isEmpty else { return (0, 0, 0) }

        let eyesOpenCount = features.filter { !$0.leftEyeClosed && !$0.rightEyeClosed }.count
        let smileCount = features.filter { $0.hasSmile }.count
        let n = Double(features.count)
        return (features.count, Double(eyesOpenCount) / n, Double(smileCount) / n)
    }
}
