import AppKit
import CoreGraphics
import Foundation
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SpaceJudgeTreemapUI

/// Compile-time architecture so the artifact never reports `unknown`.
enum SelfArchitecture {
    static let name: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()
}

/// Deterministic generator so every benchmark run is reproducible.
struct BenchRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Summary: Codable {
    let warmup: Int
    let iterations: Int
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
    let averageMs: Double
}

struct HitSummary: Codable {
    let warmup: Int
    let iterations: Int
    let queries: Int
    let averageMicroseconds: Double
    let p50Microseconds: Double
    let p95Microseconds: Double
    let maxMicroseconds: Double
}

struct BenchmarkReport: Codable {
    let seed: UInt64
    let machine: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let osVersion: String
    let architecture: String
    let parameters: [String: String]
    let layout10k: Summary
    let index2k: Summary
    let hit100k: HitSummary
    let render1280x800: Summary
    /// Pure-composer layout cost for 100 synthetic size changes. This does NOT
    /// measure the AppKit coordinator; coordinator latest-wins/cancellation is
    /// covered by the unit stress test instead.
    let resizeLayout100: Summary
    let peakResidentBytesSelfReported: UInt64?
}

/// Nanosecond clock.
@inline(__always)
func nowNanos() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func summarize(_ samples: [Double], warmup: Int) -> Summary {
    let sorted = samples.sorted()
    func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
    let total = sorted.reduce(0, +)
    return Summary(
        warmup: warmup,
        iterations: sorted.count,
        p50Ms: percentile(0.5),
        p95Ms: percentile(0.95),
        maxMs: sorted.last ?? 0,
        averageMs: sorted.isEmpty ? 0 : total / Double(sorted.count)
    )
}

func summarizeHits(_ samples: [Double], warmup: Int, queries: Int) -> HitSummary {
    let sorted = samples.sorted()
    func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
    let total = sorted.reduce(0, +)
    return HitSummary(
        warmup: warmup,
        iterations: samples.count,
        queries: queries,
        averageMicroseconds: sorted.isEmpty ? 0 : total / Double(sorted.count),
        p50Microseconds: percentile(0.5),
        p95Microseconds: percentile(0.95),
        maxMicroseconds: sorted.last ?? 0
    )
}

func makeItems(count: Int, seed: UInt64, equalWeights: Bool) -> [TreemapItem] {
    var rng = BenchRandom(seed: seed)
    return (0..<count).map { index in
        let weight: UInt64 = equalWeights ? 1_000 : (rng.next() % 1_000_000) + 1
        return TreemapItem(
            id: NodeID(UInt64(index + 2)),
            weight: weight,
            stableKey: "item-\(index)"
        )
    }
}

func makeHierarchy(count: Int, seed: UInt64, equalWeights: Bool) -> TreemapHierarchy {
    let items = makeItems(count: count, seed: seed, equalWeights: equalWeights)
    let children = items.map { item in
        TreemapHierarchyNode(
            nodeID: item.id,
            name: item.stableKey,
            kind: .regularFile,
            effectiveBytes: item.weight
        )
    }
    let page = TreemapHierarchyPage(
        parentID: NodeID(1),
        children: children,
        omittedCount: 0,
        omittedWeight: nil,
        totalDirectChildCount: UInt64(count)
    )
    let focus = TreemapHierarchyNode(
        nodeID: NodeID(1),
        name: "root",
        kind: .directory,
        effectiveBytes: 0,
        isExpanded: true,
        children: page
    )
    return TreemapHierarchy(focus: focus)
}

func makeKey(
    mode: TreemapDetailMode,
    width: Double,
    height: Double,
    revision: UInt64 = 1
) -> TreemapLayoutKey {
    TreemapLayoutKey(
        scanGeneration: 1,
        scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!),
        focusNodeID: NodeID(1),
        sceneRevision: Revision(revision),
        expansionVersion: 1,
        detailMode: mode,
        width: width,
        height: height,
        backingScale: 2
    )
}

func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return info.resident_size
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func sysctlUInt64(_ name: String) -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return value
}

// MARK: - Scenarios

let seed: UInt64 = 0x5EED_1234_ABCD_0001
let layoutIterations = 100
let layoutWarmup = 5
let indexIterations = 200
let indexWarmup = 5
let hitQueries = 100_000
let hitWarmup = 2_000
let renderIterations = 60
let renderWarmup = 5
let bounds1280 = TreemapRect(x: 0, y: 0, width: 1280, height: 800)

// 1. Pure squarified layout of 10,000 siblings.
let layoutItems = makeItems(count: 10_000, seed: seed, equalWeights: false)
let layoutInput = TreemapInput(revision: Revision(1), items: layoutItems)
let layoutEngine = SquarifiedTreemap()
for _ in 0..<layoutWarmup {
    _ = layoutEngine.layout(layoutInput, in: bounds1280)
}
var layoutSamples: [Double] = []
layoutSamples.reserveCapacity(layoutIterations)
for _ in 0..<layoutIterations {
    let start = nowNanos()
    _ = layoutEngine.layout(layoutInput, in: bounds1280)
    let end = nowNanos()
    layoutSamples.append(Double(end - start) / 1_000_000)
}

// 2. Drawable ~2,000 tile hierarchy + hit-index build.
let indexHierarchy = makeHierarchy(count: 2_000, seed: seed &+ 1, equalWeights: true)
let indexKey = makeKey(mode: .detail, width: 1280, height: 800)
let indexSnapshot = TreemapHierarchyComposer.snapshot(indexHierarchy, key: indexKey, bounds: bounds1280)
for _ in 0..<indexWarmup {
    _ = TreemapHitIndex(tiles: indexSnapshot.tiles, bounds: bounds1280)
}
var indexSamples: [Double] = []
indexSamples.reserveCapacity(indexIterations)
for _ in 0..<indexIterations {
    let start = nowNanos()
    _ = TreemapHitIndex(tiles: indexSnapshot.tiles, bounds: bounds1280)
    let end = nowNanos()
    indexSamples.append(Double(end - start) / 1_000_000)
}
let index = TreemapHitIndex(tiles: indexSnapshot.tiles, bounds: bounds1280)

// 3. Deterministic point queries: 2,000 warmup plus 100,000 measured.
var hitRng = BenchRandom(seed: seed &+ 2)
var hitSamples: [Double] = []
hitSamples.reserveCapacity(hitQueries)
for queryIndex in 0..<(hitWarmup + hitQueries) {
    let point = TreemapPoint(
        x: Double(hitRng.next() % 1_280_000) / 1_000,
        y: Double(hitRng.next() % 800_000) / 1_000
    )
    let start = nowNanos()
    _ = index.tile(at: point)
    let end = nowNanos()
    if queryIndex >= hitWarmup {
        hitSamples.append(Double(end - start) / 1_000)
    }
}
let hitSummary = summarizeHits(hitSamples, warmup: hitWarmup, queries: hitQueries)

// 4. Bitmap render at 1,280×800 using the app renderer.
let renderSnapshot = TreemapHierarchyComposer.snapshot(
    makeHierarchy(count: 2_000, seed: seed &+ 3, equalWeights: true),
    key: makeKey(mode: .detail, width: 1280, height: 800),
    bounds: bounds1280
)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let renderContext = CGContext(
    data: nil,
    width: 1_280,
    height: 800,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
) else {
    FileHandle.standardError.write(Data("unable to create bitmap context\n".utf8))
    exit(1)
}
renderContext.translateBy(x: 0, y: 800)
renderContext.scaleBy(x: 1, y: -1)
let renderer = TreemapRenderer()
let renderOptions = TreemapRenderer.Options(appearance: .light, drawsText: true)
let renderRect = CGRect(x: 0, y: 0, width: 1280, height: 800)
for _ in 0..<renderWarmup {
    renderer.render(snapshot: renderSnapshot, in: renderContext, dirtyRect: renderRect, options: renderOptions)
}
var renderSamples: [Double] = []
renderSamples.reserveCapacity(renderIterations)
for _ in 0..<renderIterations {
    let start = nowNanos()
    renderer.render(snapshot: renderSnapshot, in: renderContext, dirtyRect: renderRect, options: renderOptions)
    let end = nowNanos()
    renderSamples.append(Double(end - start) / 1_000_000)
}

// 5. Pure-composer layout cost of 100 consecutive size changes. Coordinator
//    latest-wins behavior is verified by `TreemapCoordinatorTests`.
let resizeHierarchy = makeHierarchy(count: 2_000, seed: seed &+ 4, equalWeights: true)
var resizeSamples: [Double] = []
resizeSamples.reserveCapacity(100)
for step in 0..<100 {
    let width = 900.0 + Double(step % 20) * 11
    let height = 640.0 + Double(step % 17) * 13
    let key = makeKey(mode: .overview, width: width, height: height, revision: UInt64(step + 1))
    let bounds = TreemapRect(x: 0, y: 0, width: width, height: height)
    let start = nowNanos()
    _ = TreemapHierarchyComposer.snapshot(resizeHierarchy, key: key, bounds: bounds)
    let end = nowNanos()
    resizeSamples.append(Double(end - start) / 1_000_000)
}

// MARK: - Report

let layoutSummary = summarize(layoutSamples, warmup: layoutWarmup)
let indexSummary = summarize(indexSamples, warmup: indexWarmup)
let renderSummary = summarize(renderSamples, warmup: renderWarmup)
let resizeSummary = summarize(resizeSamples, warmup: 0)

let report = BenchmarkReport(
    seed: seed,
    machine: sysctlString("hw.model"),
    processorCount: ProcessInfo.processInfo.activeProcessorCount,
    physicalMemoryBytes: sysctlUInt64("hw.memsize"),
    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
    architecture: SelfArchitecture.name,
    parameters: [
        "layoutSiblings": "10000",
        "indexTiles": "\(indexSnapshot.tiles.count)",
        "hitWarmup": "\(hitWarmup)",
        "hitMeasuredQueries": "\(hitQueries)",
        "renderWidth": "1280",
        "renderHeight": "800",
        "resizeLayoutIterations": "100"
    ],
    layout10k: layoutSummary,
    index2k: indexSummary,
    hit100k: hitSummary,
    render1280x800: renderSummary,
    resizeLayout100: resizeSummary,
    peakResidentBytesSelfReported: residentBytes()
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(report)

// Write the JSON file when requested.
var jsonPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while let first = arguments.first {
    arguments.removeFirst()
    if first == "--json", let value = arguments.first {
        jsonPath = value
        arguments.removeFirst()
    }
}
if let jsonPath {
    let url = URL(fileURLWithPath: jsonPath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try json.write(to: url)
}

let text = String(data: json, encoding: .utf8) ?? "{}"
print(text)
if let jsonPath {
    FileHandle.standardError.write(Data("wrote \(jsonPath)\n".utf8))
}
