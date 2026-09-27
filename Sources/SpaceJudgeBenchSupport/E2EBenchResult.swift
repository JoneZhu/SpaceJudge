import Foundation

/// Stable machine-readable benchmark result.
///
/// Every double is guaranteed finite before it is serialized; optional OS
/// measurements are written as JSON `null` rather than a fabricated `0`.
public struct E2EBenchResult: Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var requestedNodes: Int
    public var actualNodes: Int
    public var shape: String
    public var fixtureGenerationSeconds: Double
    public var fixtureLogicalBytes: UInt64
    public var firstStartedMillis: Double
    public var firstCommittedMillis: Double
    public var scanAndPersistSeconds: Double
    public var nodesPerSecond: Double
    public var peakResidentBytes: Int64?
    public var databaseBytesAfterClose: Int64
    public var databaseMainBytesAfterClose: Int64
    public var walBytesAfterClose: Int64
    public var shmBytesAfterClose: Int64
    public var fdBaseline: Int?
    public var fdAfterClose: Int?
    public var fdDelta: Int?
    public var status: String
    public var persistedNodes: UInt64
    public var persistedNames: UInt64
    public var persistedAggregates: UInt64
    public var rootAggregateComplete: Bool
    public var cacheState: String
    public var cancelRequestedMillis: Double?
    public var cancelTerminalMillis: Double?
    public var cancelLatencyMillis: Double?
    public var updatesAfterCancelRequest: UInt64?

    public init(
        requestedNodes: Int,
        actualNodes: Int,
        shape: String,
        fixtureGenerationSeconds: Double,
        fixtureLogicalBytes: UInt64,
        firstStartedMillis: Double,
        firstCommittedMillis: Double,
        scanAndPersistSeconds: Double,
        nodesPerSecond: Double,
        peakResidentBytes: Int64?,
        databaseBytesAfterClose: Int64,
        databaseMainBytesAfterClose: Int64,
        walBytesAfterClose: Int64,
        shmBytesAfterClose: Int64,
        fdBaseline: Int?,
        fdAfterClose: Int?,
        fdDelta: Int?,
        status: String,
        persistedNodes: UInt64,
        persistedNames: UInt64,
        persistedAggregates: UInt64,
        rootAggregateComplete: Bool,
        cacheState: String,
        cancelRequestedMillis: Double? = nil,
        cancelTerminalMillis: Double? = nil,
        cancelLatencyMillis: Double? = nil,
        updatesAfterCancelRequest: UInt64? = nil
    ) {
        self.requestedNodes = requestedNodes
        self.actualNodes = actualNodes
        self.shape = shape
        self.fixtureGenerationSeconds = fixtureGenerationSeconds
        self.fixtureLogicalBytes = fixtureLogicalBytes
        self.firstStartedMillis = firstStartedMillis
        self.firstCommittedMillis = firstCommittedMillis
        self.scanAndPersistSeconds = scanAndPersistSeconds
        self.nodesPerSecond = nodesPerSecond
        self.peakResidentBytes = peakResidentBytes
        self.databaseBytesAfterClose = databaseBytesAfterClose
        self.databaseMainBytesAfterClose = databaseMainBytesAfterClose
        self.walBytesAfterClose = walBytesAfterClose
        self.shmBytesAfterClose = shmBytesAfterClose
        self.fdBaseline = fdBaseline
        self.fdAfterClose = fdAfterClose
        self.fdDelta = fdDelta
        self.status = status
        self.persistedNodes = persistedNodes
        self.persistedNames = persistedNames
        self.persistedAggregates = persistedAggregates
        self.rootAggregateComplete = rootAggregateComplete
        self.cacheState = cacheState
        self.cancelRequestedMillis = cancelRequestedMillis
        self.cancelTerminalMillis = cancelTerminalMillis
        self.cancelLatencyMillis = cancelLatencyMillis
        self.updatesAfterCancelRequest = updatesAfterCancelRequest
    }

    /// Serializes one stable, ordered JSON object with only finite numbers.
    public func jsonString() -> String {
        let fields: [(String, String)] = [
            ("schemaVersion", String(schemaVersion)),
            ("requestedNodes", String(requestedNodes)),
            ("actualNodes", String(actualNodes)),
            ("shape", Self.quote(shape)),
            ("fixtureGenerationSeconds", Self.number(fixtureGenerationSeconds)),
            ("fixtureLogicalBytes", String(fixtureLogicalBytes)),
            ("firstStartedMillis", Self.number(firstStartedMillis)),
            ("firstCommittedMillis", Self.number(firstCommittedMillis)),
            ("scanAndPersistSeconds", Self.number(scanAndPersistSeconds)),
            ("nodesPerSecond", Self.number(nodesPerSecond)),
            ("peakResidentBytes", Self.int64(peakResidentBytes)),
            ("databaseBytesAfterClose", String(databaseBytesAfterClose)),
            ("databaseMainBytesAfterClose", String(databaseMainBytesAfterClose)),
            ("walBytesAfterClose", String(walBytesAfterClose)),
            ("shmBytesAfterClose", String(shmBytesAfterClose)),
            ("fdBaseline", Self.int(fdBaseline)),
            ("fdAfterClose", Self.int(fdAfterClose)),
            ("fdDelta", Self.int(fdDelta)),
            ("status", Self.quote(status)),
            ("persistedNodes", String(persistedNodes)),
            ("persistedNames", String(persistedNames)),
            ("persistedAggregates", String(persistedAggregates)),
            ("rootAggregateComplete", rootAggregateComplete ? "true" : "false"),
            ("cacheState", Self.quote(cacheState)),
            ("cancelRequestedMillis", Self.numberOrNull(cancelRequestedMillis)),
            ("cancelTerminalMillis", Self.numberOrNull(cancelTerminalMillis)),
            ("cancelLatencyMillis", Self.numberOrNull(cancelLatencyMillis)),
            ("updatesAfterCancelRequest", Self.uint64OrNull(updatesAfterCancelRequest))
        ]
        let body = fields.map { "  \"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
        return "{\n\(body)\n}"
    }

    // MARK: JSON helpers

    private static func quote(_ value: String) -> String {
        "\"\(value)\""
    }

    /// Six fixed decimals with a POSIX locale. Non-finite input becomes `0`
    /// defensively; callers must still avoid emitting them.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.000000" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func numberOrNull(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "null" }
        return number(value)
    }

    private static func int(_ value: Int?) -> String {
        value.map(String.init) ?? "null"
    }

    private static func int64(_ value: Int64?) -> String {
        value.map(String.init) ?? "null"
    }

    private static func uint64OrNull(_ value: UInt64?) -> String {
        value.map(String.init) ?? "null"
    }
}
