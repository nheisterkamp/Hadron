import Darwin

enum FileLock {
    // A child being spawned holds a copy of every descriptor, close-on-exec ones included, until it
    // execs. close() alone leaves the lock held by that copy, so a relock can find it busy.
    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
