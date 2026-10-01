// Capture one explicitly selected app window for documentation, without audio
// or other apps. macOS may require the caller's screen-recording permission.
// Usage: swiftc -parse-as-library record-window.swift -o record-window
//        record-window PID NEW_OUTPUT.mp4 SECONDS
import AppKit
import AVFoundation
import ScreenCaptureKit

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let queue = DispatchQueue(label: "spacejudge.documentation.video")
    var firstTimestamp: CMTime?
    var streamError: Error?

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else { throw Failure("Cannot configure video writer") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("Cannot start video writer") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if firstTimestamp == nil {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            firstTimestamp = time
            writer.startSession(atSourceTime: time)
        }
        if input.isReadyForMoreMediaData { input.append(sample) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { streamError = error }

    func finish() async throws {
        queue.sync { input.markAsFinished() }
        await writer.finishWriting()
        guard firstTimestamp != nil, writer.status == .completed else {
            throw streamError ?? writer.error ?? Failure("No complete video captured")
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main struct RecordWindow {
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            let args = CommandLine.arguments
            guard args.count == 4, let pid = Int32(args[1]),
                  let seconds = Double(args[3]), (1...300).contains(seconds),
                  args[2].hasPrefix("/"), !FileManager.default.fileExists(atPath: args[2]) else {
                throw Failure("Usage: record-window PID NEW_ABSOLUTE_OUTPUT.mp4 SECONDS (1–300)")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.filter({
                $0.owningApplication?.processID == pid
                && $0.owningApplication?.bundleIdentifier == "com.hongdazhu.SpaceJudge"
                && $0.title == "SpaceJudge"
                && $0.frame.width > 500 && $0.frame.height > 300
            }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw Failure("No visible SpaceJudge window for the specified PID")
            }
            let width = Int(window.frame.width) * 2
            let height = Int(window.frame.height) * 2
            let config = SCStreamConfiguration()
            config.width = width; config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.queueDepth = 5
            config.showsCursor = true
            config.capturesAudio = false
            let recorder = try WindowRecorder(url: URL(fileURLWithPath: args[2]), width: width, height: height)
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                  configuration: config, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
            print("Recording selected SpaceJudge window: \(width)x\(height), no audio or other apps, started \(ISO8601DateFormatter().string(from: Date()))")
            fflush(stdout)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try await stream.stopCapture()
            try await recorder.finish()
            print("Recording completed")
        } catch {
            fputs("Recording failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
