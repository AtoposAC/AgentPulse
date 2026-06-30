import Foundation

public final class StateFileWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let onChange: @MainActor @Sendable () -> Void
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    public init(stateFileURL: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.directoryURL = stateFileURL.deletingLastPathComponent()
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        stop()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        let onChange = self.onChange
        source.setEventHandler {
            Task { @MainActor in
                onChange()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
