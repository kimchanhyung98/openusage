import Foundation
import XCTest

final class PricingSupplementWorkflowTests: XCTestCase {
    func testBundledSupplementPassesPublicationValidation() throws {
        let resource = Self.repositoryRoot.appendingPathComponent(Self.resourcePath)
        let result = try validate(String(contentsOf: resource, encoding: .utf8))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Supplement OK:"), result.output)
    }

    func testBaseRatesRejectNegativeNonNumericAndNonFiniteValues() throws {
        for section in ["pricing", "pricing_v2"] {
            for field in Self.rateFields {
                for value in ["-0.1", "true", "false", "NaN", "Infinity", "-Infinity", "1e999", "\"1\""] {
                    var rates = Self.validRates
                    rates[field] = value
                    let result = try validate(fixture(section: section, rates: rates))
                    let context = "\(section).\(field)=\(value): \(result.output)"
                    XCTAssertEqual(result.status, 1, context)
                    XCTAssertTrue(result.output.contains("Supplement validation failed:"), context)
                    XCTAssertTrue(result.output.contains("\(section)[test-model].\(field)"), context)
                }
            }
        }
    }

    func testRequiredRatesRejectMissingAndNullValues() throws {
        for section in ["pricing", "pricing_v2"] {
            for field in Self.rateFields.prefix(2) {
                for value: String? in [nil, "null"] {
                    var rates = Self.validRates
                    rates[field] = value
                    let result = try validate(fixture(section: section, rates: rates))
                    XCTAssertEqual(result.status, 1, result.output)
                    XCTAssertTrue(result.output.contains("\(section)[test-model].\(field)"), result.output)
                }
            }
        }
    }

    func testZeroAndPositiveRatesAndOptionalCacheValuesRemainValid() throws {
        for section in ["pricing", "pricing_v2"] {
            for value in ["0", "0.125"] {
                let rates = Dictionary(uniqueKeysWithValues: Self.rateFields.map { ($0, value) })
                let result = try validate(fixture(section: section, rates: rates))
                XCTAssertEqual(result.status, 0, result.output)
            }
            for value: String? in [nil, "null"] {
                var rates = Self.validRates
                rates["cache_write_per_million"] = value
                rates["cache_read_per_million"] = value
                let result = try validate(fixture(section: section, rates: rates))
                XCTAssertEqual(result.status, 0, result.output)
            }
        }
    }

    private func fixture(section: String, rates: [String: String]) -> String {
        let entry = rates.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        let pricing = section == "pricing" ? "{\"test-model\":{\(entry)}}" : "{}"
        let pricingV2 = section == "pricing_v2" ? "{\"test-model\":{\(entry)}}" : "{}"
        return """
        {"updated_at":"2026-10-28T00:00:00Z","pricing":\(pricing),
         "pricing_v2":\(pricingV2),"alias_rules":[]}
        """
    }

    private func validate(_ json: String) throws -> (status: Int32, output: String) {
        let workflow = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(".github/workflows/pricing-supplement.yml"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(workflow.range(of: "          python3 - << 'PY'\n"))
        let end = try XCTUnwrap(workflow.range(of: "\n          PY", range: start.upperBound..<workflow.endIndex))
        let script = workflow[start.upperBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.dropFirst(10)) }.joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-pricing-workflow-\(UUID().uuidString)")
        let resource = directory.appendingPathComponent(Self.resourcePath)
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try json.write(to: resource, atomically: true, encoding: .utf8)

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let resourcePath = "Sources/OpenUsage/Resources/pricing_supplement.json"
    private static let rateFields = [
        "input_per_million", "output_per_million", "cache_write_per_million", "cache_read_per_million",
    ]
    private static let validRates = Dictionary(uniqueKeysWithValues: rateFields.map { ($0, "1.25") })
}
