import Foundation
import MoqomCore

final class Journal: @unchecked Sendable {
    static let shared = Journal()

    static let name = "moqom.log"

    private let queue = DispatchQueue(label: "cloud.moqom.journal", qos: .utility)
    private let url: URL?
    private var handle: FileHandle?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        url = documents.first?.appendingPathComponent(Self.name)
    }

    func begin() {
        queue.async { [self] in
            guard let url else { return }
            handle?.closeFile()
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    func say(_ line: String) {
        #if DEBUG
        print(line)
        #endif

        let stamped = Self.clock.string(from: Date()) + " " + line + "\n"
        queue.async { [self] in
            guard let data = stamped.data(using: .utf8) else { return }
            handle?.write(data)
        }
    }

    static var diagnostics: any LogSink {
        #if DEBUG
        SystemLogSink(subsystem: "cloud.moqom.sample", privacy: .hashed)
        #else
        SilentLogSink()
        #endif
    }

    struct Sink: LogSink {
        let minimum: LogLevel

        func write(_ record: LogRecord) {
            guard record.level >= minimum else { return }
            Journal.shared.say("SDK \(record.level) \(record.category) \(record.line())")
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
