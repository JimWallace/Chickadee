import Core
import Foundation

/// The four grade fields of a serialized `TestOutcomeCollection`, and the
/// grade values derived from them.
///
/// Before #1931, four functions read these fields from a collection blob, each
/// with its own `JSONSerialization` pass and an `as? Double ?? as? Int`
/// fallback, and the legacy grade path parsed one blob three times. The blob is
/// now decoded once into this type. `APIResult` builds it from its four
/// denormalized columns, so the blob and the columns share one set of formulas.
struct CollectionGradeFields: Decodable, Equatable, Sendable {
    var earnedPoints: Double?
    var totalPoints: Double?
    var passCount: Int?
    var totalTests: Int?

    init(earnedPoints: Double?, totalPoints: Double?, passCount: Int?, totalTests: Int?) {
        self.earnedPoints = earnedPoints
        self.totalPoints = totalPoints
        self.passCount = passCount
        self.totalTests = totalTests
    }

    /// Decodes the fields from a collection blob. Nil when the blob is not a
    /// JSON object.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
            let fields = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = fields
    }

    private enum CodingKeys: String, CodingKey {
        case earnedPoints, totalPoints, passCount, totalTests
    }

    /// Each field decodes on its own, so a field that is missing or not a
    /// number is nil and the other fields keep their values. A JSON integer
    /// decodes as a `Double`; a count must be a whole number.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            try? container.decodeIfPresent(Double.self, forKey: key)
        }
        earnedPoints = number(.earnedPoints)
        totalPoints = number(.totalPoints)
        passCount = number(.passCount).flatMap { Int(exactly: $0) }
        totalTests = number(.totalTests).flatMap { Int(exactly: $0) }
    }

    /// The grade as a percent: weighted (earned / total) when `totalPoints` is
    /// above zero, else passed tests over all tests. Nil when neither is
    /// available. Only a full mark reads 100 (`GradePercent`).
    var gradePercent: Int? {
        if let earnedPoints, let totalPoints, totalPoints > 0 {
            return GradePercent.of(earned: earnedPoints, total: totalPoints)
        }
        guard let passCount, let totalTests else { return nil }
        return GradePercent.of(earned: Double(passCount), total: Double(totalTests))
    }

    /// The earned points for CSV and LEARN export: weighted points when
    /// `totalPoints` is above zero, else the pass count.
    var gradePoints: Double? {
        if let totalPoints, totalPoints > 0, let earnedPoints { return earnedPoints }
        return passCount.map(Double.init)
    }

    /// The total possible points. Nil when the result predates weighted
    /// grading.
    var gradeTotalPoints: Double? {
        if let totalPoints, totalPoints > 0 { return totalPoints }
        return nil
    }
}
