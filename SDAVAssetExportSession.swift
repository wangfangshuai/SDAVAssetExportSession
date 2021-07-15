//
//  SDAVAssetExportSession.swift
//  Unicorn
//
//  Created by wangfangshuai on 2021/7/14.
//

import Foundation
import AVFoundation

@objc public protocol SDAVAssetExportSessionDelegate: NSObjectProtocol {
    @objc func exportSession(exportSession: SDAVAssetExportSession, pixelBuffer: CVPixelBuffer, presentationTime: CMTime, renderBuffer: CVPixelBuffer?)
}

public class SDAVAssetExportSession: NSObject {
    public weak var delegate: SDAVAssetExportSessionDelegate?
    public var asset: AVAsset
    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    public var outputFileType: AVFileType = .mp4
    public var outputURL: URL?
    public var videoInputSettings: Dictionary<String, Any>?
    public var videoSettings: Dictionary<String, Any>?
    public var audioSettings: Dictionary<String, Any>?
    public var timeRange: CMTimeRange?
    public var shouldOptimizeForNetworkUse: Bool?
    public var metadata: [AVMetadataItem]?
    private var privateError: Error?
    public var error: Error? {
        get {
            return privateError ?? self.writer?.error ?? self.reader?.error
        }
        set {
            privateError = newValue
        }
    }
    
    public var progress: Float?
    private var privateStatus: AVAssetExportSession.Status?
    public var status: AVAssetExportSession.Status? {
        get {
            switch self.writer?.status {
            case .unknown:
                return .unknown
            case .writing:
                return .exporting
            case .failed:
                return .failed
            case .completed:
                return .completed
            case .cancelled:
                return .cancelled
            default:
                return .unknown
            }
        }
        set {
            privateStatus = newValue
        }
    }
    
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderVideoCompositionOutput?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var inputQueue: DispatchQueue?
    private var completionHandler: (() -> Void)?
    private var duration: TimeInterval = 0
    private var lastSamplePresentationTime: CMTime?
    
    public static func exportSession(asset: AVAsset) -> SDAVAssetExportSession {
        return SDAVAssetExportSession(asset: asset)
    }
    
    public init(asset: AVAsset) {
        self.asset = asset
        self.timeRange = CMTimeRangeMake(start: .zero, duration: .positiveInfinity)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func exportAsynchronously(handler: (() -> Void)?) {
        guard let handler = handler else {
            return
        }
        self.cancelExport()
        self.completionHandler = handler
        
        guard let outputURL = self.outputURL else {
            self.error = SDAVAssetExportSessionError.outputURLNotSet
            handler()
            return
        }
        
        do {
            self.reader = try AVAssetReader(asset: self.asset)
        } catch {
            self.error = error
            handler()
            return
        }
        
        do {
            self.writer = try AVAssetWriter(url: outputURL, fileType: self.outputFileType)
        } catch {
            self.error = error
            handler()
            return
        }
        
        if let timeRange = self.timeRange {
            self.reader?.timeRange = timeRange
        }
        
        if let shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse {
            self.writer?.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
        }
        
        if let metadata = self.metadata {
            self.writer?.metadata = metadata
        }
        
        let videoTracks = self.asset.tracks(withMediaType: .video)
        
        if let timeRange = self.timeRange {
            if CMTIME_IS_VALID(timeRange.duration) && !CMTIME_IS_POSITIVEINFINITY(timeRange.duration) {
                duration = CMTimeGetSeconds(timeRange.duration)
            } else {
                duration = CMTimeGetSeconds(self.asset.duration)
            }
        }
        
        if videoTracks.count > 0 {
            self.videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: self.videoInputSettings)
            self.videoOutput?.alwaysCopiesSampleData = false
            if let videoComposition = self.videoComposition {
                self.videoOutput?.videoComposition = videoComposition
            } else {
                let videoComposition = self.buildDefaultVideoComposition()
                self.videoOutput?.videoComposition = videoComposition
            }
            if let videoOutput = self.videoOutput, let reader = self.reader {
                if reader.canAdd(videoOutput) {
                    reader.add(videoOutput)
                }
            }
            
            self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: self.videoSettings)
            self.videoInput?.expectsMediaDataInRealTime = false
            if let videoInput = self.videoInput, let writer = self.writer {
                if writer.canAdd(videoInput) {
                    writer.add(videoInput)
                }
            }
            
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: self.videoOutput!.videoComposition!.renderSize.width,
                kCVPixelBufferHeightKey as String: self.videoOutput!.videoComposition!.renderSize.height,
                "IOSurfaceOpenGLESTextureCompatibility": true,
                "IOSurfaceOpenGLESFBOCompatibility": true
            ]
            self.videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.videoInput!, sourcePixelBufferAttributes: pixelBufferAttributes)
        }
        
        let audioTracks = self.asset.tracks(withMediaType: .audio)
        if audioTracks.count > 0 {
            self.audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            self.audioOutput?.alwaysCopiesSampleData = false
            self.audioOutput?.audioMix = self.audioMix
            if let audioOutput = self.audioOutput, let reader = self.reader {
                if reader.canAdd(audioOutput) {
                    reader.add(audioOutput)
                }
            }
        } else {
            self.audioOutput = nil
        }
        
        if let audioOutput = self.audioOutput {
            self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: self.audioSettings)
            self.audioInput?.expectsMediaDataInRealTime = false
            if let audioInput = self.audioInput, let writer = self.writer {
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                }
            }
        }
        
        self.writer?.startWriting()
        self.reader?.startReading()
        self.writer?.startSession(atSourceTime: self.timeRange?.start ?? .zero)
        
        var videoComplated = false
        var audioCompleted = false
        self.inputQueue = DispatchQueue(label: "VideoEncoderInputQueue")
        if videoTracks.count > 0 {
            self.videoInput?.requestMediaDataWhenReady(on: self.inputQueue!, using: {
                if let videoOutput = self.videoOutput, let videoInput = self.videoInput {
                    if !self.encodeReadySamples(fromOutput: videoOutput, toInput: videoInput) {
                        self.inputQueue?.async {
                            videoComplated = true
                            if audioCompleted {
                                self.finish()
                            }
                        }
                    }
                }
            })
        } else {
            videoComplated = true
        }
        
        if let audioOutput = self.audioOutput {
            self.audioInput?.requestMediaDataWhenReady(on: self.inputQueue!, using: {
                if let audioOutput = self.audioOutput, let audioInput = self.audioInput {
                    if !self.encodeReadySamples(fromOutput: audioOutput, toInput: audioInput) {
                        self.inputQueue?.async {
                            audioCompleted = true
                            if videoComplated {
                                self.finish()
                            }
                        }
                    }
                }
                
            })
        } else {
            audioCompleted = true
        }
    }
    
    public func cancelExport() {
        if self.inputQueue != nil {
            self.inputQueue?.async {
                self.writer?.cancelWriting()
                self.reader?.cancelReading()
                self.complete()
                self.reset()
            }
        }
    }
    
    public func reset() {
        self.error = nil
        self.progress = 0
        self.reader = nil
        self.videoOutput = nil
        self.audioOutput = nil
        self.writer = nil
        self.videoInput = nil
        self.videoPixelBufferAdaptor = nil
        self.audioInput = nil
        self.inputQueue = nil
        self.completionHandler = nil
    }
    
    private func buildDefaultVideoComposition() -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        let videoTracks = self.asset.tracks(withMediaType: .video)
        if videoTracks.count > 0 {
            let videoTrack = videoTracks[0]
            var trackFrameRate: Float = 0
            if let videoSettings = self.videoSettings {
                if let videoCompressionProperties = videoSettings[AVVideoCompressionPropertiesKey] as? Dictionary<String, Any> {
                    if let frameRate = videoCompressionProperties[AVVideoAverageNonDroppableFrameRateKey] as? Float {
                        trackFrameRate = frameRate
                    }
                }
            } else {
                trackFrameRate = videoTrack.nominalFrameRate
            }
            
            if trackFrameRate == 0 {
                trackFrameRate = 30
            }
            
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(trackFrameRate))
            if let videoSettings = self.videoSettings {
                if let width = videoSettings[AVVideoWidthKey] as? CGFloat, let height = videoSettings[AVVideoHeightKey] as? CGFloat {
                    let targetSize = CGSize(width: width, height: height)
                    var naturalSize = videoTrack.naturalSize
                    var transform = videoTrack.preferredTransform
                    if transform.ty == -560 {
                        transform.ty = 0
                    }
                    
                    if transform.tx == -560 {
                        transform.tx = 0
                    }
                    
                    let videoAngleInDegree = Double(atan2(transform.b, transform.a)) * 180.0 / Double.pi
                    if videoAngleInDegree == 90 || videoAngleInDegree == -90 {
                        let width = naturalSize.width
                        naturalSize.width = naturalSize.height
                        naturalSize.height = width
                    }
                    videoComposition.renderSize = naturalSize
                    
                    let transformClosure = {
                        var ratio: CGFloat = 0
                        var xratio = targetSize.width / naturalSize.width
                        var yratio = targetSize.height / naturalSize.height
                        ratio = min(xratio, yratio)
                        
                        var postWidth = naturalSize.width * ratio
                        var postHeight = naturalSize.height * ratio
                        var transx = (targetSize.width - postWidth) / 2
                        var transy = (targetSize.height - postHeight) / 2
                        
                        var matrix: CGAffineTransform = CGAffineTransform(translationX: transx / xratio, y: transy / yratio)
                        matrix = matrix.scaledBy(x: ratio / xratio, y: ratio / yratio)
                        transform = transform.concatenating(matrix)
                    }
                    transformClosure()
                    
                    let passThroughInstruction = AVMutableVideoCompositionInstruction()
                    passThroughInstruction.timeRange = CMTimeRange(start: .zero, duration: self.asset.duration)
                    
                    let passThroughLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    
                    passThroughLayer.setTransform(transform, at: .zero)
                    passThroughInstruction.layerInstructions = [passThroughLayer]
                    videoComposition.instructions = [passThroughInstruction]
                    return videoComposition
                }
            }
        }
        return videoComposition
    }
    
    private func encodeReadySamples(fromOutput output: AVAssetReaderOutput, toInput input: AVAssetWriterInput) -> Bool {
        guard let reader  = self.reader, let writer = self.writer else {
            return false
        }
        
        while input.isReadyForMoreMediaData {
            if let sampleBuffer = output.copyNextSampleBuffer() {
                var handled = false
                var error = false
                
                if reader.status != AVAssetReader.Status.reading || writer.status != AVAssetWriter.Status.writing {
                    handled = true
                    error = true
                }
                
                if !handled && self.videoOutput == output {
                    self.lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    self.lastSamplePresentationTime = CMTimeSubtract(self.lastSamplePresentationTime!, self.timeRange?.start ?? .zero)
                    self.progress = (self.duration == 0) ? Float(1) : Float(CMTimeGetSeconds(self.lastSamplePresentationTime!) / self.duration)
                    
                    if let delegate = self.delegate {
                        if delegate.responds(to: #selector(SDAVAssetExportSessionDelegate.exportSession(exportSession:pixelBuffer:presentationTime:renderBuffer:))) {
                            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                                var renderBuffer: CVPixelBuffer?
                                if let videoPixelBufferAdaptor = self.videoPixelBufferAdaptor, let pixelBufferPool = videoPixelBufferAdaptor.pixelBufferPool {
                                    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &renderBuffer)
                                    delegate.exportSession(exportSession: self, pixelBuffer: pixelBuffer, presentationTime: lastSamplePresentationTime!, renderBuffer: renderBuffer)
                                    if let renderBuffer = renderBuffer {
                                        if self.videoPixelBufferAdaptor?.append(renderBuffer, withPresentationTime: self.lastSamplePresentationTime!) == nil {
                                            error = true
                                        }
                                        handled = true
                                    }
                                }
                                
                            }
                            
                        }
                    }
                }
                
                if !handled && !(input.append(sampleBuffer)) {
                    error = true
                }
                if error {
                    return false
                }
            } else {
                input.markAsFinished()
                return false
            }
        }
        return true
    }
    
    private func finish() {
        if self.reader?.status == AVAssetReader.Status.cancelled || self.writer?.status == AVAssetWriter.Status.cancelled {
            return
        }
        
        if self.writer?.status == AVAssetWriter.Status.failed {
            self.complete()
        } else if self.reader?.status == AVAssetReader.Status.failed {
            self.writer?.cancelWriting()
            self.complete()
        } else {
            self.writer?.finishWriting(completionHandler: {
                self.complete()
            })
        }
    }
    
    private func complete() {
        if self.writer?.status == AVAssetWriter.Status.failed || self.writer?.status == AVAssetWriter.Status.cancelled {
            if let outputURL = self.outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        DispatchQueue.main.async {
            if self.completionHandler != nil {
                self.completionHandler!()
                self.completionHandler = nil
            }
        }
    }
}

public enum SDAVAssetExportSessionError: Error {
    case outputURLNotSet
}
