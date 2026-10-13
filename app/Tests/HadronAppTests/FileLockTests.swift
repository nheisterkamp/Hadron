import Darwin
import Foundation
import Synchronization
import Testing

@testable import HadronApp

@Suite("File locks")
struct FileLockTests {
    @Test("A lock released while another thread spawns processes is free at once")
    func releasedDuringSpawn() throws {
        let dir = try scratchDirectory("file-lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "lock").path
        let stop = Atomic(false)
        let spawned = Atomic(0)
        Thread.detachNewThread {
            while !stop.load(ordering: .relaxed) {
                let child = Process()
                child.executableURL = URL(filePath: "/usr/bin/true")
                guard (try? child.run()) != nil else { continue }
                child.waitUntilExit()
                spawned.add(1, ordering: .relaxed)
            }
        }
        defer { stop.store(true, ordering: .relaxed) }

        var busy = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while spawned.load(ordering: .relaxed) < 200, ContinuousClock.now < deadline {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { busy += 1 }
            FileLock.release(fd)
        }
        #expect(spawned.load(ordering: .relaxed) >= 200)
        #expect(busy == 0)
    }
}
