import AVFoundation
import UIKit

/// What this Apple TV decodes, as Stream's decision engine reads it
/// (PROPOSAL §6.1, §7.6): AVPlayer's own HLS, HEVC and its HDR flavours on a
/// 4K model, Dolby Digital (Plus) and Atmos handed to the receiver. Built
/// from what the hardware says, never assumed, so a 1080p Apple TV gets
/// conversions it needs rather than a black screen.
struct Capabilities: Encodable, Equatable {
    let hls: String
    let containers: [String]
    let video: [String]
    let audio: [String]
    let maxAudioChannels: Int
    let hdr: [String]
    let maxHeight: Int

    static func current() -> Capabilities {
        let screenHeight = Int(UIScreen.main.nativeBounds.height)
        let fourK = screenHeight >= 2160 || AVPlayer.eligibleForHDRPlayback
        return make(hevc: VTIsHardwareDecodeSupportedHEVC(), hdr: AVPlayer.eligibleForHDRPlayback, fourK: fourK)
    }

    /// The pure part, for tests.
    static func make(hevc: Bool, hdr: Bool, fourK: Bool) -> Capabilities {
        Capabilities(
            hls: "native",
            // AVPlayer opens MP4 as-is; Matroska is repackaged by Stream.
            containers: ["mp4"],
            video: ["h264"] + (hevc ? ["hevc", "hevc_10"] : []),
            audio: ["aac", "mp3", "alac", "flac", "ac3", "eac3"],
            maxAudioChannels: 8,
            hdr: hdr ? ["hdr10", "hlg", "dolby_vision"] : [],
            maxHeight: fourK ? 2160 : 1080
        )
    }
}

import VideoToolbox

private func VTIsHardwareDecodeSupportedHEVC() -> Bool {
    VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
}
