import XCTest
@testable import MuxifyCore

final class SidebarFormatTests: XCTestCase {
    private let context = SidebarFormat.Context(values: [.session_name: "alpha", .branch: "feature/reward", .window_count: "2"])

    func testExpressionsAndEscapes() throws {
        let cases = [
            "#{session_name}": "alpha",
            "#{?branch,yes,no}": "yes",
            "#{?pane_title,yes,no}": "no",
            "#{?#{==:#{window_count},2},two,other}": "two",
            "#{!=:#{session_name},beta}": "1",
            "#{=3:branch}": "fea",
            "#{=-6:branch}": "reward",
            "#{=0:branch}": "",
            "#{b:branch}": "reward",
            "#{b:#{branch}}": "reward",
            "## #, #}": "# , }",
            "#{?branch,a#,b,c#}d}": "a,b",
            "#{==:##{x#},##{x#}}": "1",
            "#{?branch,##[literal],}": "#[literal]",
        ]
        for (source, expected) in cases {
            XCTAssertEqual(try SidebarFormat(source).expand(in: context), expected, source)
        }
    }

    func testLoopsUseChildValuesAndInnerLoopFlags() throws {
        let pane = SidebarFormat.Context(values: [.session_name: "alpha", .pane_index: "0"])
        let window = SidebarFormat.Context(values: [.session_name: "alpha"], loops: [.panes: [pane, pane]])
        let session = SidebarFormat.Context(values: [.session_name: "alpha"], loops: [.windows: [window]])
        let context = SidebarFormat.Context(loops: [.sessions: [session, session]])
        let source = "#{S:#{loop_index}:#{W:#{session_name}[#{P:#{loop_index}#{loop_first_flag}#{loop_last_flag}#{?loop_last_flag,,#,}}]}}"
        XCTAssertEqual(try SidebarFormat(source).expand(in: context), "0:alpha[010,101]1:alpha[010,101]")
        XCTAssertEqual(try SidebarFormat("#{W:x}").expand(in: .init()), "")
    }

    func testBadFormatsFailBeforeEvaluation() {
        for source in ["#{typo}", "#{?branch,ok,#{typo}}", "#{session_name", "#{?branch,a}",
                       "#{==:a,b,c}", "#{=x:branch}", "#[fg=red]", "#{?branch,ok,#[red]}", "#{b:missing}"] {
            XCTAssertThrowsError(try SidebarFormat(source), source)
        }
    }

    func testDefaultLinesAndEmptyTitleFallback() throws {
        let session = SidebarFormat.Context(values: [.session_base_name: "proj", .branch: "real"])
        let second = SidebarFormat.Context(values: [.session_base_name: "proj2"])
        let topic = SidebarFormat.Context(values: [.topic_title: "Title", .session_count: "2", .window_count: "3"],
                                          loops: [.sessions: [session, second]])
        let defaults = SidebarFormats.defaults
        XCTAssertEqual(defaults.text(for: .topic, in: topic, mode: .topics).summary, "proj · proj2 · 3 Windows")
        XCTAssertEqual(defaults.text(for: .topic, in: .init(), mode: .topics).summary, "No Sessions")
        XCTAssertEqual(defaults.text(for: .session, in: .init(values: [.window_count: "1"]), mode: .sessions).summary, "1 Window")
        var custom = defaults
        custom.topic.title = .init(try SidebarFormat("#{pane_title}"))
        custom.topic.summary = .init(try SidebarFormat(""))
        XCTAssertEqual(custom.text(for: .topic, in: topic, mode: .topics).title, "Title")
        XCTAssertEqual(custom.text(for: .topic, in: topic, mode: .topics).summary, "")
    }

    func testConfigParsesPerModeFormatsAndReportsOnlyInvalidField() throws {
        let source = """
        sidebar:
          agents_scope:
            topics: window
            sessions: all
          formats:
            topic:
              title: '#{topic_title}!'
              summary:
                topics: '#{misspelled}'
                sessions: 'custom'
            window:
              summary: '#{pane_current_command}'
        """
        let config = try Config.load(path: "/config") { _ in source }.get()
        XCTAssertEqual(config.sidebar.agentsScope.topics, .window)
        XCTAssertEqual(config.sidebar.agentsScope.sessions, .all)
        XCTAssertEqual(config.sidebar.formats.topic.summary.topics, SidebarFormats.defaults.topic.summary.topics)
        XCTAssertEqual(config.sidebar.formats.topic.summary.sessions.source, "custom")
        XCTAssertEqual(config.sidebar.formats.topic.title.sessions.source, "#{topic_title}!")
        XCTAssertEqual(config.sidebar.formats.window.summary.topics.source, "#{pane_current_command}")
        XCTAssertEqual(config.problems.count, 1)
        XCTAssertEqual(config.problems.first?.line, 9)
        XCTAssertTrue(config.problems.first?.message.contains("misspelled") == true)
    }

    func testAgentFormatsParseScalarAndPerModeValues() throws {
        let config = try Config.load(path: "/config") { _ in """
        sidebar:
          formats:
            agent:
              title: '#{window_name}'
              summary:
                topics: '#{topic_title}'
                sessions: '#{session_name}'
        """ }.get()
        XCTAssertTrue(config.problems.isEmpty)
        let context = SidebarFormat.Context(values: [.window_name: "shell", .topic_title: "Task", .session_name: "app"])
        for mode in [SidebarMode.topics, .sessions] {
            let text = config.sidebar.formats.text(for: .agent, in: context, mode: mode)
            XCTAssertEqual(text.title, "shell")
            XCTAssertEqual(text.summary, mode == .topics ? "Task" : "app")
        }
    }

    func testInvalidAgentFormatKeepsOnlyThatLinesDefault() throws {
        let config = try Config.load(path: "/config") { _ in """
        sidebar:
          formats:
            agent:
              title:
                topics: '#{window_name'
                sessions: '#{session_name}'
              summary: 'custom'
        """ }.get()
        XCTAssertEqual(config.problems.count, 1)
        XCTAssertEqual(config.problems.first?.line, 5)
        XCTAssertTrue(config.problems.first?.message.contains("sidebar.formats.agent.title.topics") == true)
        let context = SidebarFormat.Context(values: [.pane_label: "Agent task", .session_name: "app"])
        XCTAssertEqual(config.sidebar.formats.text(for: .agent, in: context, mode: .topics).title, "Agent task")
        XCTAssertEqual(config.sidebar.formats.text(for: .agent, in: context, mode: .sessions).title, "app")
        XCTAssertEqual(config.sidebar.formats.text(for: .agent, in: context, mode: .topics).summary, "custom")
        var formats = config.sidebar.formats
        formats.agent.title = .init(try SidebarFormat(""))
        formats.agent.summary = .init(try SidebarFormat(""))
        XCTAssertEqual(formats.text(for: .agent, in: context, mode: .sessions).title, "Agent task")
        XCTAssertEqual(formats.text(for: .agent, in: context, mode: .sessions).summary, "")
    }

    func testPartsKeepIconsEmojiAndVariableTextInOrder() throws {
        let context = SidebarFormat.Context(values: [.window_index: "3", .window_title: "#{symbol:globe}", .tab_count: "2"])
        let format = try SidebarPartFormat("#{current_app_icon} 🚀 #{window_index} #{window_title} #{symbol:globe} #{tab_count}")
        XCTAssertEqual(format.expand(in: context), [.currentAppIcon, .text(" 🚀 3 #{symbol:globe} "), .symbol("globe"), .text(" 2")])
        XCTAssertEqual(try SidebarPartFormat("##{current_app_icon#} ##{symbol:globe#}").expand(in: context),
                       [.text("#{current_app_icon} #{symbol:globe}")])
        XCTAssertEqual(try SidebarPartFormat("#{pane_title}#{P:x}").expand(in: context), [])
    }

    func testPartsAllowIconsInConditionalBranchesAndLoops() throws {
        let context = SidebarFormat.Context(loops: [.panes: [
            .init(values: [.pane_active_flag: "1", .pane_index: "0"]),
            .init(values: [.pane_active_flag: "0", .pane_index: "1"]),
        ]])
        let format = try SidebarPartFormat("#{P:#{?pane_active_flag,#{current_app_icon},#{symbol:globe}}#{pane_index}#{?loop_last_flag,,#,}}")
        XCTAssertEqual(format.expand(in: context), [.currentAppIcon, .text("0,"), .symbol("globe"), .text("1")])
        XCTAssertEqual(try SidebarPartFormat("#{?tab_count,#{symbol:globe},none}").expand(in: context), [.text("none")])
    }

    func testIconsFailInPlainFormatsAndScalarOperands() {
        for icon in ["#{current_app_icon}", "#{symbol:globe}"] {
            for source in [icon, "#{?tab_count,plain," + icon + "}", "#{P:" + icon + "}"] {
                XCTAssertThrowsError(try SidebarFormat(source), source)
            }
            for source in ["#{?" + icon + ",yes,no}", "#{==:" + icon + ",text}", "#{!=:text," + icon + "}",
                           "#{=2:" + icon + "}", "#{b:" + icon + "}",
                           "#{?#{?tab_count,text," + icon + "},yes,no}", "#{=2:#{P:" + icon + "}}"] {
                XCTAssertThrowsError(try SidebarPartFormat(source), source)
            }
        }
        for source in ["#{symbol:}", "#{symbol:#{window_title}}", "#{symbol:globe invalid}"] {
            XCTAssertThrowsError(try SidebarPartFormat(source), source)
        }
    }

    func testWindowPartsDistinguishNativeHiddenAndCustomPerMode() throws {
        let source = """
        sidebar:
          formats:
            window:
              left:
                topics: ''
                sessions: null
              right:
                topics: '#{symbol:globe} #{tab_count}'
        """
        let config = try Config.load(path: "/config") { _ in source }.get()
        XCTAssertTrue(config.problems.isEmpty)
        let context = SidebarFormat.Context(values: [.tab_count: "2", .window_title: "Window"])
        let topics = config.sidebar.formats.windowRow(in: context, mode: .topics)
        XCTAssertEqual(topics.left, [])
        XCTAssertEqual(topics.right, [.symbol("globe"), .text(" 2")])
        XCTAssertEqual(topics.text.title, "Window")
        let sessions = config.sidebar.formats.windowRow(in: context, mode: .sessions)
        XCTAssertNil(sessions.left)
        XCTAssertNil(sessions.right)
        XCTAssertNil(SidebarFormats.defaults.windowRow(in: context, mode: .topics).left)
    }

    func testConfigReportsInvalidSymbolForItsModeAndKeepsOtherParts() throws {
        let source = """
        sidebar:
          formats:
            window:
              left:
                topics: '#{current_app_icon}'
                sessions: '#{symbol:absent.muxify.symbol}'
              right:
                topics: null
                sessions: '✨ #{window_panes}'
              summary: 'unchanged'
            pane:
              left: ''
        """
        let config = try Config.load(path: "/config") { _ in source }.get()
        XCTAssertEqual(config.problems.count, 2)
        XCTAssertEqual(config.problems[0].line, 6)
        XCTAssertTrue(config.problems[0].message.contains("sidebar.formats.window.left.sessions"))
        XCTAssertTrue(config.problems[0].message.contains("absent.muxify.symbol"))
        XCTAssertTrue(config.problems[1].message.contains("sidebar.formats.pane.left"))
        XCTAssertEqual(config.sidebar.formats.windowParts.left.topics?.source, "#{current_app_icon}")
        XCTAssertNil(config.sidebar.formats.windowParts.left.sessions)
        XCTAssertNil(config.sidebar.formats.windowParts.right.topics)
        XCTAssertEqual(config.sidebar.formats.windowParts.right.sessions?.source, "✨ #{window_panes}")
        XCTAssertEqual(config.sidebar.formats.window.summary.topics.source, "unchanged")
    }

    private var tagged: SidebarFormat.Context {
        let topic: [SidebarFormat.Variable: String] = [.topic_title: "Ship", .tag_count: "2", .topic_tags: "#work #ops"]
        let tags = ["work", "ops"].map { name in
            SidebarFormat.Context(values: topic.merging([.tag: name]) { _, new in new })
        }
        return SidebarFormat.Context(values: topic, loops: [.tags: tags])
    }

    func testTheTagsLoopGivesEachTagItsNameAndPlace() throws {
        XCTAssertEqual(try SidebarFormat("#{T:#{tag}#{?loop_last_flag,, }}").expand(in: tagged), "work ops")
        XCTAssertEqual(try SidebarFormat("#{T:#{tag}=#{loop_index}#{?loop_last_flag,,;}}").expand(in: tagged), "work=0;ops=1")
        XCTAssertEqual(try SidebarFormat("#{tag_count} #{topic_tags}").expand(in: tagged), "2 #work #ops")
        XCTAssertEqual(try SidebarFormat("#{T:#{tag}}").expand(in: .init()), "", "a context with no Tags gives nothing")
        XCTAssertThrowsError(try SidebarFormat("#{T:#{tag_name}}"), "the old tag_name is an unknown variable")
    }

    func testTheTagsPartGivesOneItemPerTagAndAnEmptyItemShowsNoTag() throws {
        let items = { (source: String) in try SidebarTagsFormat(source).items(in: self.tagged).map { "\($0.index):\($0.text)" } }
        XCTAssertEqual(try items("#{T:#{tag}}"), ["0:work", "1:ops"])
        XCTAssertEqual(try items("[#{T:#{tag} (#{tag_count})}]"), ["0:work (2)", "1:ops (2)"], "text outside the loop gives no item")
        XCTAssertEqual(try items("#{T:#{?#{==:#{tag},ops},#{tag},}}"), ["1:ops"], "an empty pass leaves its Tag out")
        XCTAssertEqual(try items("#{?tag_count,#{T:#{tag}},}"), ["0:work", "1:ops"])
        XCTAssertEqual(try items(""), [], "an empty Format hides the Tags")
        XCTAssertEqual(try items("#{topic_tags}"), [], "plain text is not a Tag")
        XCTAssertThrowsError(try SidebarTagsFormat("#{T:#{symbol:tag}}"), "a Tag is text, not an icon")
        XCTAssertThrowsError(try SidebarTagsFormat("#{T:#{tags}}"))
    }

    func testConfigParsesTheTagsPartPerModeAndTheTagPlacement() throws {
        func load(_ text: String) throws -> Config { try Config.load(path: "/c.yaml") { _ in text }.get() }
        let defaults = try load("")
        XCTAssertEqual(defaults.sidebar.tagPlacement, .none, "Tags show on no card by default")
        XCTAssertEqual(defaults.sidebar.formats.topicTags.topics.source, "#{T:#{tag}}")
        XCTAssertEqual(defaults.sidebar.formats.topicTags.sessions.source, "#{T:#{tag}}")
        let custom = try load("""
        sidebar:
          tag_placement: line
          formats:
            topic:
              tags:
                topics: '#{T:#{tag} }'
                sessions: ''
        """)
        XCTAssertEqual(custom.problems, [])
        XCTAssertEqual(custom.sidebar.tagPlacement, .line)
        XCTAssertEqual(try load("sidebar:\n  tag_placement: corner").sidebar.tagPlacement, .corner)
        XCTAssertEqual(custom.sidebar.formats.topicTags.topics.source, "#{T:#{tag} }")
        XCTAssertEqual(custom.sidebar.formats.topicTags.sessions.source, "")
        XCTAssertEqual(try load("sidebar:\n  formats:\n    topic:\n      tags: null").sidebar.formats.topicTags,
                       SidebarFormats.defaults.topicTags, "null keeps the default")
        let bad = try load("""
        sidebar:
          tag_placement: summary
          formats:
            topic:
              tags: '#{T:#{nope}}'
            session:
              tags: '#{tag}'
        """)
        XCTAssertEqual(bad.problems.map { "\($0.line): \($0.message)" }, [
            "2: sidebar.tag_placement: expected none, corner, title or line",
            "5: sidebar.formats.topic.tags: unknown variable \"nope\"",
            "7: unknown key \"sidebar.formats.session.tags\"",
        ])
        XCTAssertEqual(bad.sidebar.tagPlacement, .none, "the removed summary value keeps the default")
        XCTAssertEqual(bad.sidebar.formats.topicTags, SidebarFormats.defaults.topicTags)
    }

    func testBranchReadsResolveParentAndCacheSharedPathsPerSnapshot() {
        let files = ["/repo/.git/HEAD": "ref: refs/heads/main\n", "/work/.git": "gitdir: ../meta/work\n",
                     "/meta/work/HEAD": "ref: refs/heads/feature\n", "/detached/.git/HEAD": "abcdef\n"]
        var reads: [String: Int] = [:]
        let branches = TopicBranches(paths: ["/repo", "/repo/sub", "/repo/sub/deep", "/work", "/detached"].map(Folder.local)) {
            reads[$0, default: 0] += 1
            return files[$0]
        }
        XCTAssertEqual(branches[.local("/repo/sub/deep")], "main")
        XCTAssertEqual(branches[.local("/work")], "feature")
        XCTAssertNil(branches[.local("/detached")])
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
    }
}
