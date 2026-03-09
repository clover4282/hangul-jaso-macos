import Foundation

final class FileMonitorService {
    typealias ChangeHandler = ([String]) -> Void

    private var streams: [String: FSEventStreamRef] = [:]
    private var handler: ChangeHandler?

    func setChangeHandler(_ handler: @escaping ChangeHandler) {
        self.handler = handler
    }

    func startWatching(path: String) {
        guard streams[path] == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [path] as CFArray

        guard let stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallBackInfo else { return }
                let service = Unmanaged<FileMonitorService>.fromOpaque(info).takeUnretainedValue()

                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                service.handler?(paths)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency in seconds
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        streams[path] = stream
    }

    func stopWatching(path: String) {
        guard let stream = streams.removeValue(forKey: path) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func stopAll() {
        for path in Array(streams.keys) {
            stopWatching(path: path)
        }
    }

    deinit {
        stopAll()
    }
}
