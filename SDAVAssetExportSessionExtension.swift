//
//  SDAVAssetExportSessionExtension.swift
//  Unicorn
//
//  Created by wangfangshuai on 2021/7/14.
//

import Foundation
import AVFoundation

extension SDAVAssetExportSession {
    static func compressSession(asset: AVAsset, timeRange: CMTimeRange?, outputSize: CGSize, outputURL: URL) -> SDAVAssetExportSession {
        let encoder = SDAVAssetExportSession.init(asset: asset)
//        encoder.outputFileType = AVFileType.mp4.rawValue
        encoder.outputURL = outputURL
        if let timeRange = timeRange {
            encoder.timeRange = timeRange
        }
        encoder.videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey:  outputSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2400000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40
            ]
        ];
        encoder.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
        ]
        return encoder
    }
}
