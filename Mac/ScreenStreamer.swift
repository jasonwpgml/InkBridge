import AppKit
import ScreenCaptureKit
import CoreImage

final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var frameReady: ((Data) -> Void)?
    var failed: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "inkbridge.capture", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastFrame: CFTimeInterval = 0

    func start(display: SCDisplay, content: SCShareableContent, geometry: ScreenGeometry) async throws {
        try await stop()
        let excluded = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == "local.inkbridge.desktop"
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(geometry.width)
        configuration.height = Int(geometry.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        try await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sample.imageBuffer else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 0.045 else { return }
        lastFrame = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.frameReady?(data)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.failed?(error.localizedDescription)
        }
    }
}
