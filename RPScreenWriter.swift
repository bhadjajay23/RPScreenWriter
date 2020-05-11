import Foundation
import AVFoundation
import ReplayKit

class RPScreenWriter {
    // Write video
    var videoOutputURL: URL
    var videoWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    // Write audio
    var audioOutputURL: URL
    var audioWriter: AVAssetWriter?
    var micAudioInput:AVAssetWriterInput?
    var appAudioInput:AVAssetWriterInput?
    
    var isVideoWritingFinished = false
    var isAudioWritingFinished = false
    
    var isPaused: Bool = false
    
    var sessionStartTime: CMTime = kCMTimeZero
    
    var currentTime: CMTime = kCMTimeZero {
        didSet {
            print("currentTime => \(currentTime.seconds)")
            didUpdateSeconds?(currentTime.seconds)
        }
    }
    
    var didUpdateSeconds: ((Double) -> ())?
    
    init() {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        self.videoOutputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent("RPScreenWriterVideo.mp4"))
        self.audioOutputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent("RPScreenWriterAudio.mp4"))
        removeURLsIfNeeded()
    }
    
    func removeURLsIfNeeded() {
        do {
            try FileManager.default.removeItem(at: self.videoOutputURL)
            try FileManager.default.removeItem(at: self.audioOutputURL)
        } catch {}
    }
    
    func setUpWriter() {
        do {
            try videoWriter = AVAssetWriter(outputURL: self.videoOutputURL, fileType: .mp4)
        } catch let writerError as NSError {
            print("Error opening video file \(writerError)")
        }
        
        let videoSettings = [
            AVVideoCodecKey : AVVideoCodecType.h264,
            AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
            AVVideoWidthKey  : UIScreen.main.bounds.width*2,
            AVVideoHeightKey : (UIScreen.main.bounds.height - (UIApplication.shared.statusBarFrame.height + 80)*2)*2
            ] as [String : Any]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        if let videoInput = self.videoInput,
            let canAddInput = videoWriter?.canAdd(videoInput),
            canAddInput {
            videoWriter?.add(videoInput)
        } else {
            print("couldn't add video input")
        }
        
        do {
            try audioWriter = AVAssetWriter(outputURL: self.audioOutputURL, fileType: .mp4)
        } catch let writerError as NSError {
            print("Error opening video file \(writerError)")
        }
        
        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
        let audioOutputSettings = [
            AVNumberOfChannelsKey : 6,
            AVFormatIDKey : kAudioFormatMPEG4AAC_HE,
            AVSampleRateKey : 44100,
            AVChannelLayoutKey : NSData(bytes: &channelLayout, length: MemoryLayout.size(ofValue: channelLayout))
            ] as [String : Any]
        
        appAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        if let appAudioInput = self.appAudioInput,
            let canAddInput = audioWriter?.canAdd(appAudioInput),
            canAddInput {
            audioWriter?.add(appAudioInput)
        } else {
            print("couldn't add app audio input")
        }
        micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        if let micAudioInput = self.micAudioInput,
            let canAddInput = audioWriter?.canAdd(micAudioInput),
            canAddInput {
            audioWriter?.add(micAudioInput)
        } else {
            print("couldn't add mic audio input")
        }
    }
    
    func writeBuffer(_ cmSampleBuffer: CMSampleBuffer, rpSampleType: RPSampleBufferType) {
        if self.videoWriter == nil {
            self.setUpWriter()
        }
        guard let videoWriter = self.videoWriter,
            let audioWriter = self.audioWriter,
            !isPaused else {
                return
        }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(cmSampleBuffer)
        switch rpSampleType {
        case .video:
            if videoWriter.status == .unknown {
                if videoWriter.startWriting() {
                    print("video writing started")
                    self.sessionStartTime = presentationTimeStamp
                    videoWriter.startSession(atSourceTime: presentationTimeStamp)
                }
            } else if videoWriter.status == .writing {
                if let isReadyForMoreMediaData = videoInput?.isReadyForMoreMediaData,
                    isReadyForMoreMediaData {
                    self.currentTime = CMTimeSubtract(presentationTimeStamp, self.sessionStartTime)
                    if let appendInput = videoInput?.append(cmSampleBuffer),
                        !appendInput {
                        print("couldn't write video buffer")
                    }
                }
            }
            break
        case .audioApp:
            if audioWriter.status == .unknown {
                if audioWriter.startWriting() {
                    print("audio writing started")
                    audioWriter.startSession(atSourceTime: presentationTimeStamp)
                }
            } else if audioWriter.status == .writing {
                if let isReadyForMoreMediaData = appAudioInput?.isReadyForMoreMediaData,
                    isReadyForMoreMediaData {
                    if let appendInput = appAudioInput?.append(cmSampleBuffer),
                        !appendInput {
                        print("couldn't write app audio buffer")
                    }
                }
            }
            break
        case .audioMic:
            if audioWriter.status == .unknown {
                if audioWriter.startWriting() {
                    print("audio writing started")
                    audioWriter.startSession(atSourceTime: presentationTimeStamp)
                }
            } else if audioWriter.status == .writing {
                if let isReadyForMoreMediaData = micAudioInput?.isReadyForMoreMediaData,
                    isReadyForMoreMediaData {
                    if let appendInput = micAudioInput?.append(cmSampleBuffer),
                        !appendInput {
                        print("couldn't write mic audio buffer")
                    }
                }
            }
            break
        }
    }
    
    func finishWriting(completionHandler handler: @escaping (URL?, Error?) -> Void) {
        self.videoInput?.markAsFinished()
        self.videoWriter?.finishWriting {
            self.isVideoWritingFinished = true
            completion()
        }
        
        self.appAudioInput?.markAsFinished()
        self.micAudioInput?.markAsFinished()
        self.audioWriter?.finishWriting {
            self.isAudioWritingFinished = true
            completion()
        }
        
        func completion() {
            if self.isVideoWritingFinished && self.isAudioWritingFinished {
                self.isVideoWritingFinished = false
                self.isAudioWritingFinished = false
                self.isPaused = false
                self.videoInput = nil
                self.videoWriter = nil
                self.appAudioInput = nil
                self.micAudioInput = nil
                self.audioWriter = nil
                merge()
            }
        }
        
        func merge() {
            let mergeComposition = AVMutableComposition()
            
            let videoAsset = AVAsset(url: self.videoOutputURL)
            let videoTracks = videoAsset.tracks(withMediaType: .video)
            print(videoAsset.duration.seconds)
            let videoCompositionTrack = mergeComposition.addMutableTrack(withMediaType: .video,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            do {
                try videoCompositionTrack?.insertTimeRange(CMTimeRange(start: kCMTimeZero, end: videoAsset.duration),
                                                           of: videoTracks.first!,
                                                           at: kCMTimeZero)
            } catch let error {
                removeURLsIfNeeded()
                handler(nil, error)
            }
            videoCompositionTrack?.preferredTransform = videoTracks.first!.preferredTransform
            
            let audioAsset = AVAsset(url: self.audioOutputURL)
            let audioTracks = audioAsset.tracks(withMediaType: .audio)
            print(audioAsset.duration.seconds)
            for audioTrack in audioTracks {
                let audioCompositionTrack = mergeComposition.addMutableTrack(withMediaType: .audio,
                                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                do {
                    try audioCompositionTrack?.insertTimeRange(CMTimeRange(start: kCMTimeZero, end: audioAsset.duration),
                                                               of: audioTrack,
                                                               at: kCMTimeZero)
                } catch let error {
                    print(error)
                }
            }
            let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
            let outputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent("RPScreenWriterMergeVideo.mp4"))
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {}

            let exportSession = AVAssetExportSession(asset: mergeComposition,
                                                     presetName: AVAssetExportPresetHighestQuality)
            exportSession?.outputFileType = .mp4
            exportSession?.shouldOptimizeForNetworkUse = true
            exportSession?.outputURL = outputURL
            exportSession?.exportAsynchronously {
                if let error = exportSession?.error {
                    self.removeURLsIfNeeded()
                    handler(nil, error)
                } else {
                    self.removeURLsIfNeeded()
                    handler(exportSession?.outputURL, nil)
                }
            }
        }
    }
}
