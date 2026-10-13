import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runtime rows on the Status pane")
struct RuntimeRowTests {

    private func install(
        _ name: String, _ support: RuntimeSupport = .supported(shippedRuntime),
        root: String = "/runtimes", isManual: Bool = false
    ) -> RuntimeInstall {
        RuntimeInstall(root: URL(filePath: "\(root)/\(name)", directoryHint: .isDirectory),
                       support: support, isManual: isManual)
    }

    private func rows(
        _ installs: [RuntimeInstall],
        installed: [RunnerBuild] = [],
        damaged: [String] = [],
        orphaned: [String] = [],
        incomplete: [String] = []
    ) -> [RuntimeRow] {
        RuntimeRow.rows(
            installs: installs, installed: installed,
            damaged: damaged, orphaned: orphaned, incomplete: incomplete
        )
    }

    @Test("A runtime with no copy yet can be set up")
    func runtimeWithoutCopy() {
        let runtime = install("wine")

        let made = rows([runtime])

        #expect(made.count == 1)
        #expect(made[0].copy == .none)
        #expect(made[0].buildID == shippedRuntimeID)
        #expect(made[0].install?.id == runtime.id)
        #expect(made[0].canSetUp)
        #expect(made[0].title == runtime.name)
        #expect(made[0].build == shippedRuntime)
    }

    @Test("A runtime with its copy installed is ready")
    func readyCopy() {
        let runtime = install("wine")

        let made = rows([runtime], installed: [shippedRuntime])

        #expect(made.map(\.copy) == [.ready])
        #expect(made[0].canSetUp)
        #expect(made[0].id == runtime.id)
    }

    @Test("A copy whose runtime folder is gone keeps a row that cannot be recopied")
    func copyWithoutRuntime() {
        let made = rows([], installed: [shippedRuntime])

        #expect(made.count == 1)
        #expect(made[0].install == nil)
        #expect(made[0].copy == .ready)
        #expect(!made[0].canSetUp)
        #expect(made[0].title == "Hadron \(shippedRuntime.displayVersion)")
        #expect(made[0].id == shippedRuntimeID)
    }

    @Test("A copy missing a built-in is incomplete, even though it is installed")
    func incompleteCopy() {
        let made = rows([install("wine")], installed: [shippedRuntime], incomplete: [shippedRuntimeID])

        #expect(made.map(\.copy) == [.incomplete])
        #expect(made[0].canSetUp)
    }

    @Test("A damaged copy is marked on the runtime's row, or on its own when the runtime is gone")
    func damagedCopy() {
        #expect(rows([install("wine")], damaged: [shippedRuntimeID]).map(\.copy) == [.damaged])

        let alone = rows([], damaged: [shippedRuntimeID])
        #expect(alone.map(\.copy) == [.damaged])
        #expect(alone[0].install == nil)
        #expect(!alone[0].canSetUp)
    }

    @Test("A copy of a build Hadron no longer serves is unsupported, on its own row")
    func orphanedCopy() {
        let made = rows([install("wine")], installed: [shippedRuntime], orphaned: ["wine-0.1"])

        #expect(made.map(\.copy) == [.ready, .unsupported])
        #expect(made[1].buildID == "wine-0.1")
        #expect(made[1].install == nil)
        #expect(made[1].build == nil)
        #expect(made[1].title == "Hadron wine-0.1")
        #expect(!made[1].canSetUp)
    }

    @Test("Every copy state on one pane, in order")
    func everyState() {
        let made = rows(
            [install("wine"), install("old", .unsupportedBuild("wine-0.2"))],
            installed: [shippedRuntime], orphaned: ["wine-0.1"], incomplete: [shippedRuntimeID]
        )

        #expect(made.map(\.copy) == [.incomplete, .none, .unsupported])
        #expect(made.map(\.unsupportedVersion) == [nil, "wine-0.2", nil])
    }

    @Test("Two runtimes of the same build share one row, the first one given")
    func sameBuildTwice() {
        let first = install("wine")
        let second = install("wine", root: "/Volumes/Spare")

        let made = rows([first, second], installed: [shippedRuntime])

        #expect(made.map(\.install?.id) == [first.id])
    }

    @Test("A runtime Hadron doesn't support is listed with its version and nothing to set up")
    func unsupportedRuntime() {
        let old = install("old", .unsupportedBuild("wine-0.1"))

        let made = rows([old])

        #expect(made.count == 1)
        #expect(made[0].unsupportedVersion == "wine-0.1")
        #expect(made[0].copy == .none)
        #expect(!made[0].canSetUp)
        #expect(made[0].title == "Hadron wine-0.1")
    }

    @Test("A manually added runtime says so on its row")
    func manualRow() {
        #expect(rows([install("wine", isManual: true)])[0].isManual)
        #expect(!rows([install("wine")])[0].isManual)
        #expect(!rows([], installed: [shippedRuntime])[0].isManual)
    }

    @Test("A picked runtime is found under the row for its build, or its path when unsupported")
    func pickedRuntimeListing() {
        let first = install("wine")
        let second = install("wine", root: "/Volumes/Spare")

        let made = rows([first], installed: [shippedRuntime])

        #expect(RuntimeRow.listing(first, in: made)?.id == first.id)
        #expect(RuntimeRow.listing(second, in: made)?.id == first.id)

        // A copy without its runtime folder has no row a picked runtime can land on.
        #expect(RuntimeRow.listing(first, in: rows([], installed: [shippedRuntime])) == nil)

        let old = install("old", .unsupportedBuild("wine-0.1"))
        #expect(RuntimeRow.listing(old, in: rows([old]))?.id == old.id)
        #expect(RuntimeRow.listing(old, in: made) == nil)
        let oldElsewhere = install("old", .unsupportedBuild("wine-0.1"), root: "/Volumes/Spare")
        #expect(RuntimeRow.listing(oldElsewhere, in: rows([old])) == nil)
    }
}
