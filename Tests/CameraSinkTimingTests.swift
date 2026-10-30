import CoreMedia

@main
struct CameraSinkTimingTests {
    static func main() {
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                     CMTime(value: -1, timescale: 1), CMTime(value: Int64.max, timescale: 1)] {
            precondition(SinkTiming.hostTimeInNanoseconds(time) == nil)
        }
        precondition(SinkTiming.hostTimeInNanoseconds(.zero) == 0)
        precondition(SinkTiming.hostTimeInNanoseconds(CMTime(value: 3, timescale: 2)) == 1_500_000_000)
        precondition(SinkTiming.hostTimeInNanoseconds(CMTime(value: 1, timescale: 3)) == 333_333_333)
        precondition(SinkTiming.hostTimeInNanoseconds(CMTime(value: Int64.max, timescale: 1_000_000_000)) == UInt64(Int64.max))
        print("Sink timing: invalid, infinite, negative and overflowing timestamps drop; valid values preserve nanoseconds")
    }
}
