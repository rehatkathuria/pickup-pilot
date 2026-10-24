import Foundation
import Darwin

public final class SingleInstanceLock {
    private let descriptor: Int32
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstanceError.cannotOpen }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw InstanceError.alreadyRunning
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    public enum InstanceError: Error { case cannotOpen, alreadyRunning }
}
