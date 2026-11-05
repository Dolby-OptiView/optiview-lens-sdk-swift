import Foundation

#if canImport(AudioToolbox)
    import AudioToolbox
#endif
#if canImport(VideoToolbox)
    import VideoToolbox
#endif

/// The Dolby decoder claims of the platform, detected once per process: the
/// hardware Dolby Vision decoder VideoToolbox reports and the Dolby audio
/// decoders AudioToolbox has installed, independent of any source and of
/// DRM. A claim, not proof of what was rendered; an adapter that knows better
/// overrides it field by field.
internal enum Capabilities {
    /// What detection reads — the platform's decoders, or a test's stand-in.
    /// A probe that answers nil leaves its claim unknown.
    struct Probes {
        var dolbyVision: () -> Bool?
        var audioDecoder: (String) -> Bool?
    }

    /// In reporting order; `ec-3-joc` is not probed and sits after `ec-3`.
    private static let audioCodecs = ["ac-3", "ec-3", "ac-4"]

    /// What `probes` claim. Apple decodes E-AC-3 JOC wherever it decodes
    /// E-AC-3, so `ec-3-joc` follows `ec-3`. One unknown audio probe leaves
    /// the whole list unknown, never partial.
    static func probe(_ probes: Probes) -> LensPlayerCapabilities {
        var codecs: [String]? = []
        for codec in audioCodecs {
            guard let supported = probes.audioDecoder(codec) else {
                codecs = nil
                break
            }
            if supported { codecs?.append(codec) }
            if supported && codec == "ec-3" { codecs?.append("ec-3-joc") }
        }
        return LensPlayerCapabilities(dolbyVision: probes.dolbyVision(), dolbyAudioCodecs: codecs)
    }

    private static let platformProbes = Probes(
        dolbyVision: {
            #if canImport(VideoToolbox)
                return VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
            #else
                return nil
            #endif
        },
        audioDecoder: { codec in
            #if canImport(AudioToolbox)
                var format = codec.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                var size: UInt32 = 0
                let status = AudioFormatGetPropertyInfo(
                    kAudioFormatProperty_Decoders, UInt32(MemoryLayout<UInt32>.size), &format,
                    &size)
                if status == kAudioFormatUnsupportedDataFormatError { return false }
                return status == noErr ? size > 0 : nil
            #else
                return nil
            #endif
        }
    )

    private static let lock = NSLock()
    private nonisolated(unsafe) static var detected: LensPlayerCapabilities?
    private nonisolated(unsafe) static var probesOverride: Probes?

    /// The platform's claims; the first call detects them.
    static func platform() -> LensPlayerCapabilities {
        lock.lock()
        defer { lock.unlock() }
        if let detected { return detected }
        let result = probe(probesOverride ?? platformProbes)
        detected = result
        return result
    }

    // --- Test seams — not part of the production path ---

    static func setProbesForTesting(_ probes: Probes?) {
        lock.lock()
        defer { lock.unlock() }
        probesOverride = probes
        detected = nil
    }
}
