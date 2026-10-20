import XCTest
@testable import SqueezeCore

final class EstimatorTests: XCTestCase {
    func testZerosCompressAlmostCompletely() {
        XCTAssertLessThan(Estimator.ratio(of: zeros(1 << 20)), 0.05)
    }

    func testRandomDataDoesNotCompress() {
        XCTAssertEqual(Estimator.ratio(of: randomBytes(1 << 18)), 1, accuracy: 0.001)
    }

    func testEmptyDataRatioIsOne() {
        XCTAssertEqual(Estimator.ratio(of: Data()), 1)
    }

    func testEstimateOfZerosIsNearlyEverything() throws {
        let dir = try makeTempDir(self)
        let a = try write(zeros(1 << 20), to: dir.appendingPathComponent("a"))
        let b = try write(zeros(2 << 20), to: dir.appendingPathComponent("b"))
        let files = [FileItem(url: a, size: 1 << 20), FileItem(url: b, size: 2 << 20)]
        let total = Int64(3 << 20)
        let saved = Estimator.estimateSavings(of: files)
        XCTAssertGreaterThan(saved, total * 9 / 10)
        XCTAssertLessThanOrEqual(saved, total)
    }

    func testEstimateOfRandomIsAlmostZero() throws {
        let dir = try makeTempDir(self)
        let a = try write(randomBytes(1 << 20), to: dir.appendingPathComponent("a"))
        let saved = Estimator.estimateSavings(of: [FileItem(url: a, size: 1 << 20)])
        XCTAssertLessThan(saved, 10_000)
    }

    func testEstimateMixed() throws {
        let dir = try makeTempDir(self)
        let z = try write(zeros(1 << 20), to: dir.appendingPathComponent("z"))
        let r = try write(randomBytes(1 << 20), to: dir.appendingPathComponent("r"))
        let saved = Estimator.estimateSavings(of: [FileItem(url: z, size: 1 << 20), FileItem(url: r, size: 1 << 20)])
        // roughly half of the data compresses away
        XCTAssertGreaterThan(saved, 800_000)
        XCTAssertLessThan(saved, 1_200_000)
    }

    func testEstimateNoFiles() {
        XCTAssertEqual(Estimator.estimateSavings(of: []), 0)
    }

    func testEstimateSkipsUnreadableFiles() {
        let ghost = FileItem(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), size: 1000)
        XCTAssertEqual(Estimator.estimateSavings(of: [ghost]), 0)
    }
}
