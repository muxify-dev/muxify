import XCTest
@testable import MuxifyCore

final class SampleDigestTests: XCTestCase {
    /// A real `sample` of the app while SwiftUI's graph updates ran every frame, trimmed to its main thread's larger
    /// branches and two other threads.
    private func fixture() throws -> SampleDigest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-swiftui-bound.txt", withExtension: nil,
                                                  subdirectory: "Fixtures"))
        return try XCTUnwrap(SampleDigest(sample: try String(contentsOf: url, encoding: .utf8)))
    }

    func testTheMainThreadOfASwiftUIBoundSampleIsBusyInAttributeGraphAndSwiftUI() throws {
        let digest = try fixture()
        XCTAssertEqual(digest.samples, 2083)
        // 45 samples wait in __CFRunLoopServiceMachPort.
        XCTAssertEqual(digest.busySamples, 2038)
        XCTAssertEqual(digest.busy, 97.8, accuracy: 0.05)

        XCTAssertEqual(digest.libraries.map(\.name), ["AttributeGraph", "SwiftUICore", "QuartzCore", "libobjc.A.dylib",
                                                      "AppKit", "SwiftUI", "libsystem_kernel.dylib", "CoreFoundation"])
        XCTAssertEqual(digest.libraries[0].percent, 58.8, accuracy: 0.05)
        XCTAssertEqual(digest.libraries[1].percent, 11.8, accuracy: 0.05)
        let swiftUI = digest.libraries.filter { ["AttributeGraph", "SwiftUICore", "SwiftUI"].contains($0.name) }
        XCTAssertGreaterThan(swiftUI.map(\.percent).reduce(0, +), 70)
        // The wait is not busy time: the kernel keeps only what it took outside it.
        XCTAssertEqual(try XCTUnwrap(digest.libraries.first { $0.name == "libsystem_kernel.dylib" }).percent, 1.5, accuracy: 0.05)

        XCTAssertEqual(digest.symbols.count, SampleDigest.topSymbols)
        XCTAssertEqual(digest.symbols.prefix(6).map { "\($0.name) in \($0.library ?? "-")" }, [
            "AG::Graph::UpdateStack::update() in AttributeGraph",
            "AG::Graph::propagate_dirty(AG::AttributeID) in AttributeGraph",
            "AG::Subgraph::update(unsigned int) in AttributeGraph",
            "DisplayList.ViewUpdater.update(container:from:parentState:) in SwiftUICore",
            "CA::Display::DisplayLink::dispatch_deferred_display_links(unsigned int) in QuartzCore",
            "objc_release in libobjc.A.dylib",
        ])
        XCTAssertEqual(digest.symbols[0].percent, 23.8, accuracy: 0.05)
        XCTAssertFalse(digest.symbols.contains { $0.name == "mach_msg2_trap" && $0.percent > 2 })
        XCTAssertEqual(digest.symbols.map(\.percent), digest.symbols.map(\.percent).sorted(by: >))

        XCTAssertEqual(digest.frames.prefix(5).map(\.name), [
            "main", "closure #1 in TerminalActivityGlyph.body.getter", "<deduplicated_symbol>",
            "closure #3 in closure #1 in WorkspaceStore.refresh(attachIfNeeded:)", "???",
        ])
        XCTAssertEqual(digest.frames[0].percent, 100, accuracy: 0.05)
        XCTAssertEqual(digest.frames[1].percent, 0.7, accuracy: 0.05)
        XCTAssertTrue(digest.frames.allSatisfy { $0.library == nil })
        XCTAssertLessThanOrEqual(digest.frames.count, SampleDigest.topFrames)
    }

    func testTheRecordsNameTheSampleAndStayOneWordAValue() throws {
        let records = try fixture().records(file: "burst-2026-11-02-131229.txt")
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertEqual(record.kind, .digest)
            XCTAssertEqual(record["sample"], "burst-2026-11-02-131229.txt")
            let parsed = try XCTUnwrap(DiagnosticsRecord.parse(record.line(at: Date())), record.text)
            XCTAssertEqual(parsed.record, record)
            XCTAssertFalse(record.text.contains("\n"))
        }
        XCTAssertEqual(records[0]["samples"], "2083")
        XCTAssertEqual(records[0]["busy"], "97.8")
        XCTAssertEqual(records[0].pairs("libraries")?.first.map { "\($0.name)=\($0.value)" }, "AttributeGraph=58.8")

        let symbols = try XCTUnwrap(records[1].pairs("symbols"))
        XCTAssertEqual(symbols.count, 15)
        XCTAssertEqual(symbols[0].name, "AG::Graph::UpdateStack::update()@AttributeGraph")
        XCTAssertEqual(symbols[0].value, "23.8")
        XCTAssertEqual(symbols[2].name, "AG::Subgraph::update(...)@AttributeGraph")
        XCTAssertTrue(symbols.allSatisfy { Double($0.value) != nil && $0.name.contains("@") }, "\(symbols)")

        let frames = try XCTUnwrap(records[2].pairs("frames"))
        XCTAssertEqual(frames[0].name, "main")
        XCTAssertEqual(frames[1].name, "closure_#1_in_TerminalActivityGlyph.body.getter")
        XCTAssertTrue(frames.allSatisfy { Double($0.value) != nil }, "\(frames)")
    }

    func testSelfIsTheCountLessTheChildrenAndAnAppFrameCountsOncePerPath() throws {
        let sample = """
        Process:         MuxifyApp [42]

        Call graph:
            10 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 10 main  (in MuxifyApp) + 1  [0x1]
            +   4 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0x2]
            +   ! 4 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0x3]
            +   6 Store.refresh()  (in MuxifyApp.debug.dylib) + 1  [0x4]
            +     5 Store.refresh()  (in MuxifyApp.debug.dylib) + 1  [0x4]
            +     ! 3 AG::Graph::update(unsigned int, bool)  (in AttributeGraph) + 1  [0x5]
            +     ! 1 objc_release  (in libobjc.A.dylib) + 1  [0x6]
            10 Thread_2
            + 10 objc_release  (in libobjc.A.dylib) + 1  [0x6]

        Binary Images:
        """
        let digest = try XCTUnwrap(SampleDigest(sample: sample))
        XCTAssertEqual(digest.samples, 10)
        XCTAssertEqual(digest.busySamples, 6)
        XCTAssertEqual(digest.busy, 60, accuracy: 0.001)
        // Of 6 busy samples: AttributeGraph 3, the app 1 + 1 (the outer refresh's own and the inner one's own), objc 1.
        XCTAssertEqual(digest.libraries.map(\.name), ["AttributeGraph", "MuxifyApp.debug.dylib", "libobjc.A.dylib"])
        XCTAssertEqual(digest.libraries.map(\.percent), [50, 100.0 / 3, 100.0 / 6])
        XCTAssertEqual(digest.symbols.map(\.name), ["AG::Graph::update(unsigned int, bool)", "Store.refresh()", "objc_release"])
        // main holds every busy sample; the recursive refresh counts its 6 once, not 6 + 5.
        XCTAssertEqual(digest.frames.map(\.name), ["Store.refresh()", "main"])
        XCTAssertEqual(digest.frames.map(\.percent), [100, 100])
        XCTAssertEqual(digest.records(file: "freeze-x.txt")[1]["symbols"],
                       "AG::Graph::update(...)@AttributeGraph:50.0,Store.refresh()@MuxifyApp.debug.dylib:33.3,"
                       + "objc_release@libobjc.A.dylib:16.7")
    }

    func testASampleWithNoMainThreadHasNoDigest() {
        XCTAssertNil(SampleDigest(sample: "Call graph:\n    10 Thread_2\n    + 10 objc_release  (in libobjc.A.dylib) + 1\n"))
        XCTAssertNil(SampleDigest(sample: ""))
    }

    func testAnAllIdleMainThreadHasNoShares() throws {
        let digest = try XCTUnwrap(SampleDigest(sample: """
            5 Thread_1: Main Thread   DispatchQueue_<multiple>
            + 5 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0x2]
            + ! 5 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0x3]
        """))
        XCTAssertEqual(digest.busy, 0)
        XCTAssertEqual(digest.libraries, [])
        XCTAssertEqual(digest.records(file: "f.txt")[2]["frames"], "none")
    }

    func testASymbolIsShortenedToOneWord() {
        XCTAssertEqual(SampleDigest.short("CA::Display::DisplayLink::dispatch_items(unsigned long long, unsigned long long)"),
                       "CA::Display::DisplayLink::dispatch_items(...)")
        XCTAssertEqual(SampleDigest.short("specialized static TopicSessionOrder.ordered<A>(_:record:order:key:)"),
                       "specialized_static_TopicSessionOrder.ordered<A>(_:record:order:key:)")
        XCTAssertEqual(SampleDigest.short("CA::DisplayLinkItem::dispatch_(CA::SignPost::Interval<(CA::Code)8>&)"),
                       "CA::DisplayLinkItem::dispatch_(...)")
        XCTAssertEqual(SampleDigest.short("-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:]"),
                       "-[NSApplication(NSEventRouting)_nextEventMatchingMask:untilDate:]")
        XCTAssertEqual(SampleDigest.short("Dictionary<String, Int>.init(a,b)"), "Dictionary<...>.init(...)")
        XCTAssertEqual(SampleDigest.short("a, b"), "a;_b")
        let long = SampleDigest.short(String(repeating: "x", count: 200))
        XCTAssertEqual(long.count, SampleDigest.symbolLength)
        XCTAssertTrue(long.hasSuffix("..."))
    }
}

final class SampleRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func file(_ name: String, daysAgo: Double, megabytes: Int64 = 1) -> SampleRetention.File {
        SampleRetention.File(name: name, modified: now.addingTimeInterval(-daysAgo * day), bytes: megabytes << 20)
    }

    func testSamplesOlderThanThreeDaysAreDeletedOldestFirst() {
        let files = [
            file("freeze-new.txt", daysAgo: 0.1), file("burst-4d.txt", daysAgo: 4), file("cpu-10d.txt", daysAgo: 10),
            file("burst-2d.txt", daysAgo: 2.9), file("freeze-3d.txt", daysAgo: 3.1),
        ]
        XCTAssertEqual(SampleRetention.doomed(files, now: now), ["cpu-10d.txt", "burst-4d.txt", "freeze-3d.txt"])
    }

    func testSamplesOverThreeHundredMegabytesInAllAreDeletedOldestFirst() {
        let files = [
            file("burst-a.txt", daysAgo: 0.5, megabytes: 120), file("burst-b.txt", daysAgo: 0.4, megabytes: 120),
            file("freeze-c.txt", daysAgo: 0.3, megabytes: 50), file("freeze-d.txt", daysAgo: 0.2, megabytes: 20),
            file("burst-e.txt", daysAgo: 0.1, megabytes: 100),
        ]
        // Newest first: e 100, d 120, c 170, b 290 are kept; a would make 410.
        XCTAssertEqual(SampleRetention.doomed(files, now: now), ["burst-a.txt"])
        let more = files + [file("burst-f.txt", daysAgo: 0.05, megabytes: 100)]
        // f 100, e 200, d 220, c 270 are kept; b and a go, a first.
        XCTAssertEqual(SampleRetention.doomed(more, now: now), ["burst-a.txt", "burst-b.txt"])
    }

    func testOnlyRawSampleFilesAreDeleted() {
        let files = [
            file("muxify-2026-11-01.log", daysAgo: 10, megabytes: 400), file("notes.txt", daysAgo: 10),
            file("freeze-old.log", daysAgo: 10), file("freeze-old.txt", daysAgo: 10),
        ]
        XCTAssertEqual(SampleRetention.doomed(files, now: now), ["freeze-old.txt"])
        XCTAssertEqual(SampleRetention.doomed([], now: now), [])
    }
}
