import XCTest
@testable import Pebrel

final class PebrelCoreTests: XCTestCase {
    func testBase64Url32StrictRoundTrip() {
        let bytes = Data(0..<32)
        let encoded = CryptoHelpers.encodeBase64UrlNoPad(bytes)
        XCTAssertEqual(encoded.count, 43)
        XCTAssertEqual(CryptoHelpers.decodeBase64Url32(encoded), bytes)
        XCTAssertNil(CryptoHelpers.decodeBase64Url32(encoded + "="))
        XCTAssertNil(CryptoHelpers.decodeBase64Url32("short"))
    }

    func testRelayProfileV2ValidationAndDualRouteOrder() {
        let hostKey = CryptoHelpers.encodeBase64UrlNoPad(Data(repeating: 0x11, count: 32))
        let secret = CryptoHelpers.encodeBase64UrlNoPad(Data(repeating: 0x22, count: 32))
        let token = String(repeating: "A", count: 43)
        let pin = "sha256/" + Data(repeating: 0x33, count: 32).base64EncodedString()

        let relayJson = """
        {"version":2,"mode":"relay","url":"wss://relay.example.com","device":"room-1","token":"\(token)","tlsPin":"\(pin)","name":"Studio Mac","hostOs":"macos","secure":{"host":"\(hostKey)","grant":"dev-1","secret":"\(secret)","invitation":false,"expiresAt":0}}
        """
        let lanJson = """
        {"version":2,"mode":"lan","url":"wss://192.168.1.50:54321","device":"room-1","token":"\(token)","tlsPin":"\(pin)","name":"Studio Mac","hostOs":"macos","secure":{"host":"\(hostKey)","grant":"dev-1","secret":"\(secret)","invitation":false,"expiresAt":0}}
        """

        let relayProfile = RelayProfile.parse(relayJson)
        let lanProfile = RelayProfile.parse(lanJson)
        XCTAssertNotNil(relayProfile)
        XCTAssertNotNil(lanProfile)
        XCTAssertEqual(relayProfile?.id, lanProfile?.id)

        let merged = relayProfile!.retainRoutes(from: lanProfile)
        let routes = merged.connectionRoutes()
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].mode, "lan")
        XCTAssertEqual(routes[1].mode, "relay")

        // v1 must reject secure block (no silent E2EE downgrade)
        let badV1 = relayJson.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")
        XCTAssertNil(RelayProfile.parse(badV1))
    }

    func testSshEndpointParsingAndSessionValidation() {
        let parsed = SshEndpointParser.parse("alice@[2001:db8::1]")
        XCTAssertEqual(parsed?.user, "alice")
        XCTAssertEqual(parsed?.host, "2001:db8::1")
        XCTAssertNil(SshEndpointParser.parse("ssh://example.com"))
        XCTAssertNil(SshEndpointParser.parse("a@b@c"))

        XCTAssertTrue(SshEndpointParser.isValidRemoteSessionName("work_01", mode: .tmux))
        XCTAssertFalse(SshEndpointParser.isValidRemoteSessionName("-bad", mode: .tmux))
        XCTAssertTrue(SshEndpointParser.isValidRemoteSessionName("proj.v1", mode: .herdr))
        XCTAssertFalse(SshEndpointParser.isValidRemoteSessionName("proj.v1", mode: .tmux))
    }

    func testTerminalShortcutParsingAndDefaults() {
        XCTAssertEqual(TerminalShortcut.defaults.count, 8)
        let ctrlC = TerminalShortcut.parse("ctrl+c")
        XCTAssertEqual(ctrlC?.label, "Ctrl+C")
        XCTAssertEqual(ctrlC?.modifiers, TerminalShortcut.modCtrl)
        XCTAssertEqual(ctrlC?.desktopKeyName, "c")
        XCTAssertNil(TerminalShortcut.parse("Ctrl+Ctrl+C"))
        XCTAssertNil(TerminalShortcut.parse("InvalidKey"))
    }

    func testDesktopScreenFrameAndDeltaSync() {
        let theme = PebrelThemeCatalog.shared.palette(named: "Nord", systemIsDark: true).terminalColors
        let full: [String: Any] = [
            "screen_seq": 1,
            "screen": [
                "version": 1,
                "columns": 4,
                "rows": [
                    [["h", 1, -257, -258, 0], ["i", 1, -257, -258, 1], [" ", 1, -257, -258, 0], [" ", 1, -257, -258, 0]],
                    [["中", 2, 0xFF0000, -258, 0], ["!", 1, -257, -258, 0], [" ", 1, -257, -258, 0]],
                ],
                "cursor": [1, 0, 1],
                "wrapped": [false, false],
            ],
        ]
        let sync = DesktopScreenSync()
        let frame1 = sync.apply(target: "d:1:1", response: full, theme19: theme)
        XCTAssertNotNil(frame1)
        XCTAssertEqual(frame1?.rows[0].plainLine(), "hi")
        XCTAssertEqual(frame1?.rows[1].plainLine(), "中!")

        let delta: [String: Any] = [
            "screen_seq": 2,
            "screen_delta": [
                "base": 1,
                "rows": [
                    [0, [["o", 1, -257, -258, 0], ["k", 1, -257, -258, 0], [" ", 1, -257, -258, 0], [" ", 1, -257, -258, 0]]]
                ],
            ],
        ]
        let frame2 = sync.apply(target: "d:1:1", response: delta, theme19: theme)
        XCTAssertEqual(frame2?.rows[0].plainLine(), "ok")
        XCTAssertEqual(frame2?.rows[1].plainLine(), "中!")

        let reflowed = TerminalReflow.reflow(frame2!, columns: 2)
        XCTAssertEqual(reflowed.columns, 2)
        XCTAssertGreaterThanOrEqual(reflowed.rows.count, 3)
    }

    func testTerminalSelectionWordAndSoftWrap() {
        let theme = PebrelThemeCatalog.shared.palette(named: "MintLight", systemIsDark: false).terminalColors
        let full: [String: Any] = [
            "screen_seq": 1,
            "screen": [
                "version": 1,
                "columns": 5,
                "rows": [
                    [["h", 1, -257, -258, 0], ["e", 1, -257, -258, 0], ["l", 1, -257, -258, 0], ["l", 1, -257, -258, 0], ["o", 1, -257, -258, 0]],
                    [["w", 1, -257, -258, 0], ["o", 1, -257, -258, 0], ["r", 1, -257, -258, 0], ["l", 1, -257, -258, 0], ["d", 1, -257, -258, 0]],
                ],
                "cursor": [0, 0, 1],
                "wrapped": [true, false],
            ],
        ]
        let frame = DesktopScreenSync().apply(target: "t", response: full, theme19: theme)!
        let all = TerminalSelectionState.selectAll(in: frame)!
        XCTAssertEqual(all.selectedText(), "helloworld")
    }

    func testReaderMarkdownMathMermaidAndLinks() {
        let colors = PebrelThemeCatalog.shared.palette(named: "MintLight", systemIsDark: false).readerColors
        let md = """
        # Hello
        Price is $10 and formula is $E = mc^2$.

        ```mermaid
        graph TD
          A --> B
        ```

        [Docs](./guide.md)
        """
        let doc = ReaderMarkdown.prepareMarkdown(text: md, colors: colors, copyLabel: "Copy")
        XCTAssertTrue(doc.hasRichContent)
        XCTAssertEqual(doc.headings.count, 1)
        XCTAssertEqual(doc.headings[0].id, "hello")
        XCTAssertEqual(doc.links, ["./guide.md"])
        XCTAssertTrue(doc.html.contains("math-render"))
        XCTAssertTrue(doc.html.contains("data-diagram"))
        XCTAssertTrue(doc.html.contains("$10"))
        XCTAssertEqual(ReaderMarkdown.resolveRelativeLink(basePath: "/repo/docs/index.md", link: "./guide.md"), "/repo/docs/guide.md")
    }

    func testTerminalPromptParser() {
        let screen = """
        Allow editing main.swift?
        ❯ 1. Yes, allow once
          2. No, deny
        Thinking (12s · esc to interrupt)
        """
        XCTAssertTrue(TerminalPromptParser.isRunning(screen))
        XCTAssertEqual(TerminalPromptParser.activity(screen), "Thinking (12s)")
        let prompt = TerminalPromptParser.parse(screen)
        XCTAssertNotNil(prompt)
        XCTAssertEqual(prompt?.options, ["Yes, allow once", "No, deny"])
        XCTAssertEqual(prompt?.selected, 0)
    }

    func testGitTreeBuilderAndSftpPaths() throws {
        let entries = [
            GitStatusEntry(path: "src/app/a.swift", original: nil, index: "M", worktree: ".", conflict: false),
            GitStatusEntry(path: "src/app/b.swift", original: nil, index: "A", worktree: ".", conflict: false),
        ]
        let expanded = GitTreeBuilder.build(entries: entries, collapsedFolders: [])
        XCTAssertEqual(expanded.count, 4)
        let collapsed = GitTreeBuilder.build(entries: entries, collapsedFolders: ["src/app"])
        XCTAssertEqual(collapsed.count, 2)

        XCTAssertEqual(try SftpPaths.child(parent: "/home/u", name: "a.txt"), "/home/u/a.txt")
        XCTAssertEqual(SftpPaths.parent(of: "/home/u/a.txt"), "/home/u")
        XCTAssertEqual(VoiceInputController.appendVoiceDraft("ls", spoken: "-la"), "ls -la")
    }
}
