import CoreMedia

/// Convert producer timing without trapping on invalid or overflowing values.
enum SinkTiming {
    static func hostTimeInNanoseconds(_ time: CMTime) -> UInt64? {
        guard time.isNumeric, time.value >= 0 else { return nil }
        let nanoseconds = CMTimeConvertScale(time, timescale: 1_000_000_000,
                                            method: .roundTowardZero)
        guard nanoseconds.isNumeric, nanoseconds.value >= 0 else { return nil }
        return UInt64(nanoseconds.value)
    }
}
