// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin
import Foundation
import Testing

@testable import VigilCore

func process(
    _ pid: Int32, parent: Int32 = 1, name: String = "proc", user: String = "me", cpu: Double? = nil,
    memory: UInt64? = nil, start: UInt64 = 1_000, restricted: Bool = false
) -> ProcessEntry {
    ProcessEntry(
        id: ProcessIdentity(pid: pid, startMicroseconds: start), parentPID: parent, uid: 501, user: user, name: name,
        path: "/Applications/\(name).app/Contents/MacOS/\(name)", state: .running, isRestricted: restricted, cpu: cpu,
        memory: memory)
}

@Suite struct ProcessRateTests {
    let window = SampleWindow(
        previous: MonotonicInstant(nanoseconds: 0), current: MonotonicInstant(nanoseconds: 2_000_000_000),
        expectedInterval: 2)

    @Test func cpuFractionAndDiskRates() throws {
        let previous = ProcessCounters(cpuNanoseconds: 1_000_000_000, diskRead: 0, diskWritten: 100, footprint: 1)
        let current = ProcessCounters(cpuNanoseconds: 2_000_000_000, diskRead: 4_096, diskWritten: 100, footprint: 1)
        let rates = ProcessCounters.rates(previous: previous, current: current, window: window)
        #expect(try #require(rates.cpu) == 0.5)  // 1 s of CPU over 2 s = half a core
        #expect(try #require(rates.read) == 2_048)
        #expect(try #require(rates.write) == 0)
    }

    @Test func multithreadedProcessesCanExceedOneCore() throws {
        let previous = ProcessCounters(cpuNanoseconds: 0, diskRead: 0, diskWritten: 0, footprint: 1)
        let current = ProcessCounters(cpuNanoseconds: 6_000_000_000, diskRead: 0, diskWritten: 0, footprint: 1)
        #expect(try #require(ProcessCounters.rates(previous: previous, current: current, window: window).cpu) == 3)
    }

    @Test func firstSampleHasNoRates() {
        let current = ProcessCounters(cpuNanoseconds: 5, diskRead: 5, diskWritten: 5, footprint: 1)
        #expect(ProcessCounters.rates(previous: nil, current: current, window: window).cpu == nil)
    }
}

@Suite struct ProcessListTests {
    let processes = [
        process(1, parent: 0, name: "launchd", cpu: 0.01),
        process(100, parent: 1, name: "Safari", cpu: 0.30, memory: 900),
        process(101, parent: 100, name: "Safari Web Content", cpu: 0.50, memory: 400),
        process(102, parent: 100, name: "Safari Networking", cpu: 0.05, memory: 100),
        process(200, parent: 1, name: "WindowServer", user: "_windowserver", restricted: true),
        process(300, parent: 1, name: "Terminal", cpu: 0.10, memory: 300),
    ]

    @Test func flatListSortsByCPUDescendingWithRestrictedLast() {
        let rows = ProcessListBuilder.rows(processes, query: ProcessQuery())
        #expect(rows.map(\.entry.pid) == [101, 100, 300, 102, 1, 200])
        #expect(rows.allSatisfy { $0.depth == 0 })
    }

    @Test func ascendingStillPutsMissingValuesLast() {
        var query = ProcessQuery()
        query.ascending = true
        #expect(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid) == [1, 102, 300, 100, 101, 200])
    }

    @Test func sortByNameIsCaseInsensitive() {
        var query = ProcessQuery()
        query.sort = .name
        query.ascending = true
        let names = ProcessListBuilder.rows(processes, query: query).map(\.entry.name)
        #expect(names == ["launchd", "Safari", "Safari Networking", "Safari Web Content", "Terminal", "WindowServer"])
    }

    @Test func filterMatchesNameUserAndPID() {
        var query = ProcessQuery()
        query.filter = "safari"
        #expect(Set(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid)) == [100, 101, 102])
        query.filter = "_windowserver"
        #expect(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid) == [200])
        query.filter = "300"
        #expect(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid) == [300])
    }

    @Test func slashesMeanARegularExpression() {
        var query = ProcessQuery()
        query.filter = "/^safari (web|net)/"
        #expect(Set(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid)) == [101, 102])
    }

    @Test func invalidRegexMatchesNothingInsteadOfCrashing() {
        var query = ProcessQuery()
        query.filter = "/[unclosed/"
        #expect(ProcessListBuilder.rows(processes, query: query).isEmpty)
    }

    @Test func treePutsChildrenUnderParentsSortedWithinSiblings() {
        var query = ProcessQuery()
        query.tree = true
        let rows = ProcessListBuilder.rows(processes, query: query)
        #expect(rows.map(\.entry.pid) == [1, 100, 101, 102, 300, 200])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 1])
        #expect(rows[1].hasChildren)
        #expect(!rows[2].hasChildren)
    }

    @Test func collapsedParentsHideTheirChildren() {
        var query = ProcessQuery()
        query.tree = true
        query.collapsed = [ProcessIdentity(pid: 100, startMicroseconds: 1_000)]
        let rows = ProcessListBuilder.rows(processes, query: query)
        #expect(rows.map(\.entry.pid) == [1, 100, 300, 200])
        #expect(rows[1].isCollapsed)
    }

    @Test func filteredTreeKeepsAncestorsOfMatches() {
        var query = ProcessQuery()
        query.tree = true
        query.filter = "networking"
        #expect(ProcessListBuilder.rows(processes, query: query).map(\.entry.pid) == [1, 100, 102])
    }

    @Test func orphansAndSelfParentedProcessesBecomeRoots() {
        let odd = [process(5, parent: 5, name: "self"), process(6, parent: 999, name: "orphan")]
        var query = ProcessQuery()
        query.tree = true
        #expect(Set(ProcessListBuilder.rows(odd, query: query).map(\.entry.pid)) == [5, 6])
    }

    @Test func topSkipsProcessesWithoutData() {
        let metrics = ProcessMetrics(processes: processes)
        #expect(metrics.top(2, by: .cpu).map(\.pid) == [101, 100])
        #expect(metrics.top(2, by: .memory).map(\.pid) == [100, 101])
        #expect(metrics.restrictedCount == 1)
    }
}

@Suite struct ProcessArgumentTests {
    func bytes(argc: Int32, path: String, arguments: [String], environment: [String] = ["HOME=/Users/me"]) -> [UInt8] {
        var data = withUnsafeBytes(of: argc) { Array($0) }
        data += Array(path.utf8) + [0, 0, 0, 0]  // path + padding
        for argument in arguments + environment { data += Array(argument.utf8) + [0] }
        return data
    }

    @Test func parsesArgumentsAndStopsBeforeTheEnvironment() {
        let parsed = ProcessArguments.parse(
            bytes(argc: 3, path: "/usr/bin/swift", arguments: ["swift", "build", "-c release"]))
        #expect(parsed == ["swift", "build", "-c release"])
    }

    @Test func malformedBuffersAreRejected() {
        #expect(ProcessArguments.parse([1, 0]) == nil)
        #expect(ProcessArguments.parse(bytes(argc: 4, path: "/bin/ls", arguments: ["ls"], environment: [])) == nil)
        #expect(ProcessArguments.parse(bytes(argc: -1, path: "/bin/ls", arguments: [])) == nil)
    }

    @Test func readsOurOwnArguments() throws {
        let arguments = try #require(ProcessArguments.read(getpid()))
        #expect(!arguments.isEmpty)
    }
}

@Suite(.serialized) struct ProcessCollectorIntegrationTests {
    @Test func seesEveryProcessAndStatsForOurOwn() async throws {
        let sampler = Sampler(configuration: .init(interval: 2, demand: [.processes, .processDetails]))
        let start = MonotonicInstant.now
        _ = await sampler.sample(at: start)
        try? await Task.sleep(for: .milliseconds(100))
        let snapshot = await sampler.sample(at: MonotonicInstant(nanoseconds: start.nanoseconds + 2_000_000_000))
        let metrics = try #require(snapshot.processes)
        #expect(metrics.processes.count > 50)
        let me = try #require(metrics.processes.first { $0.pid == getpid() })
        #expect(!me.isRestricted)
        #expect(me.memory ?? 0 > 0)
        #expect(me.cpu != nil)
        #expect((me.threads ?? 0) >= 1)
        #expect(me.user == NSUserName())
        // launchd belongs to root: visible, but its statistics are restricted.
        let launchd = try #require(metrics.processes.first { $0.pid == 1 })
        #expect(launchd.isRestricted)
        #expect(launchd.cpu == nil)
        #expect(launchd.name == "launchd")
    }

    @Test func signalingAStaleIdentityIsRefused() {
        // Our own PID with the wrong start time: must not be signaled.
        let stale = ProcessIdentity(pid: getpid(), startMicroseconds: 1)
        #expect(ProcessSignals.send(.resume, to: stale) == .processGone)
        #expect(ProcessSignals.isSensitive(1))
        #expect(ProcessSignals.isSensitive(getpid()))
    }
}

@Suite(.serialized) struct ProcessDemandTests {
    @Test func addingDetailsKeepsRates() async throws {
        let sampler = Sampler(configuration: .init(interval: 2, demand: [.processes]))
        let start = MonotonicInstant.now
        _ = await sampler.sample(at: start)
        await sampler.setDemand([.processes, .processDetails])  // the Dashboard opens
        let snapshot = await sampler.sample(at: MonotonicInstant(nanoseconds: start.nanoseconds + 2_000_000_000))
        let me = try #require(snapshot.processes?.processes.first { $0.pid == getpid() })
        #expect(me.cpu != nil)  // no reset: rates continue
        #expect(me.threads != nil)
    }
}
