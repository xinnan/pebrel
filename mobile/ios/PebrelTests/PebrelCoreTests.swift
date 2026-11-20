import Darwin
import Network
import SwiftUI
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

    func testPinnedLeafX509HandlesRcgenLongValidityAndSan() {
        func derTLV(_ tag: UInt8, _ content: Data) -> Data {
            var out = Data([tag])
            let n = content.count
            if n < 128 {
                out.append(UInt8(n))
            } else if n < 256 {
                out.append(0x81)
                out.append(UInt8(n))
            } else {
                out.append(0x82)
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
            }
            out.append(content)
            return out
        }

        let spki = derTLV(0x30, Data(repeating: 0xAB, count: 32))
        let pin = "sha256/" + CryptoHelpers.sha256Base64(spki)
        let wrongPin = "sha256/" + CryptoHelpers.sha256Base64(Data(repeating: 0xCD, count: 32))

        // Match rcgen::generate_simple_self_signed: 1975-01-01 UTCTime .. 4096-01-01 GeneralizedTime, no EKU
        let validity = derTLV(
            0x30,
            derTLV(0x17, Data("750101000000Z".utf8)) + derTLV(0x18, Data("40960101000000Z".utf8))
        )
        let ipv4 = Data([192, 168, 1, 50])
        let ipv6 = Data([0xFD, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let sanNames = derTLV(
            0x30,
            derTLV(0x87, ipv4) + derTLV(0x87, ipv6) + derTLV(0x82, Data("*.example.com".utf8))
        )
        let sanExt = derTLV(
            0x30,
            derTLV(0x06, Data([0x55, 0x1D, 0x11])) + derTLV(0x04, sanNames)
        )
        let extensions = derTLV(0xA3, derTLV(0x30, sanExt))
        let tbs = derTLV(
            0x30,
            derTLV(0xA0, derTLV(0x02, Data([0x02])))
                + derTLV(0x02, Data([0x01]))
                + derTLV(0x30, Data())
                + derTLV(0x30, Data())
                + validity
                + derTLV(0x30, Data())
                + spki
                + extensions
        )
        let certDER = derTLV(0x30, tbs + derTLV(0x30, Data()) + derTLV(0x03, Data([0x00])))

        let now2026: Int64 = 1_795_000_000
        XCTAssertNil(PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: pin, expectedHost: "192.168.1.50", nowUnix: now2026))
        XCTAssertNil(PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: pin, expectedHost: "[fd00::1]", nowUnix: now2026))
        XCTAssertNil(PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: pin, expectedHost: "relay.example.com", nowUnix: now2026))
        XCTAssertEqual(
            PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: wrongPin, expectedHost: "192.168.1.50", nowUnix: now2026),
            .certificateChanged
        )
        XCTAssertEqual(
            PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: pin, expectedHost: "192.168.1.99", nowUnix: now2026),
            .tls
        )
        XCTAssertEqual(
            PinnedTlsSessionDelegate.evaluatePinnedLeafDER(certDER, expectedPin: pin, expectedHost: "192.168.1.50", nowUnix: 100),
            .certificateDate
        )
    }

    func testDesktopRuntimeClientQueuesEarlyApprovalAndReady() async throws {
        let transport = EarlyApprovalTransport()
        let client = DesktopRuntimeClient(transport: transport, allowInput: true)
        var receivedCode: String?
        var receivedSnapshot: DesktopSnapshot?
        client.onApproval = { receivedCode = $0.code }
        client.onSnapshot = { receivedSnapshot = $0 }

        try await client.connect()
        XCTAssertEqual(receivedCode, "123456")
        XCTAssertEqual(receivedSnapshot?.processId, 42)
        XCTAssertEqual(client.hostOs, "linux")
        client.close()
    }

    func testDesktopZoomRangeAndPosixFailureClassification() {
        var prefs = TerminalPreferences()
        prefs.desktopZoom = 0.25
        XCTAssertEqual(prefs.normalized().desktopZoom, 0.25, accuracy: 0.001)
        prefs.desktopZoom = 0.05
        XCTAssertEqual(prefs.normalized().desktopZoom, 0.2, accuracy: 0.001)
        prefs.desktopZoom = 9.0
        XCTAssertEqual(prefs.normalized().desktopZoom, 5.0, accuracy: 0.001)

        let timedOut = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        XCTAssertEqual(DesktopFailureClassifier.classify(timedOut), .timeout)
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        XCTAssertEqual(DesktopFailureClassifier.classify(refused), .refused)

        XCTAssertEqual(DesktopFailureClassifier.classify(NWError.tls(-9807), relayReached: false), .tls)
        XCTAssertEqual(DesktopFailureClassifier.classify(NWError.posix(.ECONNREFUSED), relayReached: false), .refused)
        XCTAssertEqual(DesktopFailureClassifier.classify(NWError.posix(.ETIMEDOUT), relayReached: false), .timeout)
        XCTAssertEqual(DesktopFailureClassifier.classify(NWError.posix(.ECONNRESET), relayReached: true), .disconnected)
        XCTAssertEqual(DesktopFailureClassifier.fromNWWebSocketClose(.protocolCode(.policyViolation)), .protocol)
        XCTAssertEqual(DesktopFailureClassifier.fromNWWebSocketClose(.protocolCode(.messageTooBig)), .protocol)
        XCTAssertEqual(DesktopFailureClassifier.fromNWWebSocketClose(.protocolCode(.normalClosure)), .disconnected)
    }

    func testDesktopConversationSupportsAntigravityAgent() {
        XCTAssertTrue(DesktopConversation.supportedKinds.contains("claude"))
        XCTAssertTrue(DesktopConversation.supportedKinds.contains("codex"))
        XCTAssertTrue(DesktopConversation.supportedKinds.contains("antigravity"))
        XCTAssertFalse(DesktopConversation.supportedKinds.contains("aider"))

        let snapshot = DesktopSnapshot.parse([
            "process_id": 7,
            "revision": 3,
            "windows": [[
                "id": 1,
                "tabs": [[
                    "index": 0,
                    "label": "agy",
                    "kind": "shell",
                    "active": true,
                    "panes": [[
                        "id": 9,
                        "title": "agy",
                        "cwd": "/work",
                        "running_program": "antigravity",
                        "task_state": "finished",
                        "state_change_seq": 5,
                        "agent": [
                            "kind": "antigravity",
                            "display_name": "Antigravity",
                            "session_id": "021267b4-1ed5-4421-be03-c4d2054f5cae",
                        ],
                    ]],
                ]],
            ]],
        ])
        let pane = snapshot.panes.first
        XCTAssertEqual(pane?.agent?.kind, "antigravity")
        XCTAssertEqual(pane?.agent?.displayName, "Antigravity")
        XCTAssertEqual(pane?.agent?.sessionId, "021267b4-1ed5-4421-be03-c4d2054f5cae")
    }

    func testChatMarkdownBlockParsingCoversRichStructures() {
        let md = """
        # Summary ##

        > Outer quote
        > > Nested quote

        1. First step
           ```swift
           let x = 1
           ```
        2. Second step
          - [ ] Pending task
          - [x] Done task

        | Name | Expr | Count |
        | :--- | :---: | ---: |
        | `a | b` | x \\| y | 42 |

        ---

        $$E = mc^2$$

        ```mermaid
        graph TD
          A --> B
        ```
        """
        let doc = ChatMarkdownParser.parse(md)
        XCTAssertTrue(doc.hasRichContent)
        XCTAssertTrue(doc.hasCodeOrTable)
        XCTAssertEqual(doc.blocks.count, 7)

        XCTAssertEqual(doc.blocks[0], .heading(level: 1, text: "Summary"))
        XCTAssertEqual(
            doc.blocks[1],
            .quote([
                .paragraph("Outer quote"),
                .quote([.paragraph("Nested quote")]),
            ])
        )
        XCTAssertEqual(
            doc.blocks[2],
            .list(ordered: true, start: 1, items: [
                ChatMarkdownListItem(checked: nil, blocks: [
                    .paragraph("First step"),
                    .code(language: "swift", code: "let x = 1"),
                ]),
                ChatMarkdownListItem(checked: nil, blocks: [
                    .paragraph("Second step"),
                    .list(ordered: false, start: 1, items: [
                        ChatMarkdownListItem(checked: false, blocks: [.paragraph("Pending task")]),
                        ChatMarkdownListItem(checked: true, blocks: [.paragraph("Done task")]),
                    ]),
                ]),
            ])
        )
        XCTAssertEqual(
            doc.blocks[3],
            .table(
                headers: ["Name", "Expr", "Count"],
                alignments: [.leading, .center, .trailing],
                rows: [["`a | b`", "x | y", "42"]]
            )
        )
        XCTAssertEqual(doc.blocks[4], .rule)
        XCTAssertEqual(doc.blocks[5], .math("E = mc^2"))
        XCTAssertEqual(doc.blocks[6], .code(language: "mermaid", code: "graph TD\n  A --> B"))

        // Streaming unclosed code fence must still parse cleanly as a code block.
        let streaming = ChatMarkdownParser.parse("```rust\nfn main() {")
        XCTAssertEqual(streaming.blocks, [.code(language: "rust", code: "fn main() {")])
        XCTAssertTrue(streaming.hasCodeOrTable)
        XCTAssertFalse(streaming.hasRichContent)
    }

    func testChatMarkdownInlineFormattingMathGuardsAndLinkSafety() {
        let style = ChatInlineStyle(
            baseFont: .body,
            codeFont: .system(.callout, design: .monospaced),
            foregroundColor: .primary,
            linkColor: .blue,
            codeBackground: .gray.opacity(0.2),
            mathBackground: .blue.opacity(0.1),
            imageLabel: "Open image"
        )

        // Currency must NOT trigger math; genuine LaTeX MUST trigger math.
        let currencyDoc = ChatMarkdownParser.parse("Price is $10 and total is $20, escaped \\$100.")
        XCTAssertFalse(currencyDoc.hasRichContent)
        XCTAssertFalse(ChatMarkdownInline.containsInlineMath("Cost $10+$20 or $1,234.56"))
        XCTAssertTrue(ChatMarkdownInline.containsInlineMath("Energy $E = mc^2$ and \\(a + b\\)"))

        // CJK bold, intra-word snake_case / dunder non-emphasis, and multiplication spaces.
        let cjk = ChatMarkdownInline.render("**加粗（测试）**后面 my_var_name foo__bar__baz 2 * 3 * 4", style: style)
        XCTAssertEqual(String(cjk.characters), "加粗（测试）后面 my_var_name foo__bar__baz 2 * 3 * 4")

        // Safe vs unsafe link schemes (http/https/mailto allowed; javascript:/file: stripped of tap link).
        XCTAssertNotNil(ChatMarkdownInline.safeLinkURL("https://example.com/docs"))
        XCTAssertNotNil(ChatMarkdownInline.safeLinkURL("mailto:dev@example.com"))
        XCTAssertNil(ChatMarkdownInline.safeLinkURL("javascript:alert(1)"))
        XCTAssertNil(ChatMarkdownInline.safeLinkURL("file:///home/nan/code/pebrel/main.rs"))

        let mixedLinks = ChatMarkdownInline.render(
            "See [Docs](https://example.com) and [main.rs](file:///home/nan/main.rs) and [xss](javascript:alert(1))",
            style: style
        )
        XCTAssertEqual(String(mixedLinks.characters), "See Docs and main.rs and xss")
        let urls = mixedLinks.runs.compactMap { $0[AttributeScopes.FoundationAttributes.LinkAttribute.self]?.absoluteString }
        XCTAssertEqual(urls, ["https://example.com"])

        // Images render as text/link label without loading remote content.
        let img = ChatMarkdownInline.render("![Arch](https://example.com/arch.png)", style: style)
        XCTAssertEqual(String(img.characters), "Open image · Arch")
        XCTAssertEqual(
            img.runs.compactMap { $0[AttributeScopes.FoundationAttributes.LinkAttribute.self]?.absoluteString },
            ["https://example.com/arch.png"]
        )
    }

    func testConversationAutoEntryDetectionAndSuppressionKeys() {
        func makePane(agent: DesktopAgentInfo?) -> DesktopPane {
            DesktopPane(
                id: 9,
                window: 1,
                title: "agy",
                cwd: "/work",
                runningProgram: "antigravity",
                taskState: "idle",
                stateChangeSeq: 1,
                sshDestination: nil,
                agent: agent
            )
        }

        let agyPane = makePane(agent: DesktopAgentInfo(kind: "antigravity", displayName: "Antigravity", sessionId: "conv-1"))
        XCTAssertEqual(
            ConversationAutoEntry.desktopTarget(for: agyPane),
            ConversationAutoEntry.DesktopTarget(kind: "antigravity", session: "conv-1")
        )

        // Negative cases: missing/empty sessionId, unsupported kind, or nil agent must NOT auto-enter.
        XCTAssertNil(ConversationAutoEntry.desktopTarget(for: makePane(agent: DesktopAgentInfo(kind: "antigravity", displayName: "Antigravity", sessionId: nil))))
        XCTAssertNil(ConversationAutoEntry.desktopTarget(for: makePane(agent: DesktopAgentInfo(kind: "claude", displayName: "Claude", sessionId: ""))))
        XCTAssertNil(ConversationAutoEntry.desktopTarget(for: makePane(agent: DesktopAgentInfo(kind: "aider", displayName: "Aider", sessionId: "conv-2"))))
        XCTAssertNil(ConversationAutoEntry.desktopTarget(for: makePane(agent: nil)))

        // SSH auto-entry triggers only when ready and foreground reports an agent.
        let fgClaude = SshForeground(program: "claude", cwd: "~/repo", agent: "claude", multiplexer: nil)
        let fgShell = SshForeground(program: "zsh", cwd: "~/repo", agent: nil, multiplexer: nil)
        XCTAssertEqual(ConversationAutoEntry.sshKind(status: "ready", foreground: fgClaude), "claude")
        XCTAssertNil(ConversationAutoEntry.sshKind(status: "connecting", foreground: fgClaude))
        XCTAssertNil(ConversationAutoEntry.sshKind(status: "ready", foreground: fgShell))
        XCTAssertNil(ConversationAutoEntry.sshKind(status: "ready", foreground: nil))

        // Suppression keys match their pane/session prefixes for cleanup when an agent exits.
        let deskKey = ConversationAutoEntry.desktopKey(desktopId: "d1", windowId: 1, paneId: 9, kind: "antigravity", session: "conv-1")
        let deskPrefix = ConversationAutoEntry.desktopPanePrefix(desktopId: "d1", windowId: 1, paneId: 9)
        XCTAssertTrue(deskKey.hasPrefix(deskPrefix))
        XCTAssertFalse(deskKey.hasPrefix(ConversationAutoEntry.desktopPanePrefix(desktopId: "d1", windowId: 1, paneId: 10)))

        let sshKey = ConversationAutoEntry.sshKey(sessionId: "s1", kind: "claude")
        XCTAssertTrue(sshKey.hasPrefix(ConversationAutoEntry.sshSessionPrefix(sessionId: "s1")))
        XCTAssertFalse(sshKey.hasPrefix(ConversationAutoEntry.sshSessionPrefix(sessionId: "s2")))
    }
}

private final class EarlyApprovalTransport: DesktopTransport {
    var transportLabel: String { "LAN" }
    var onFrame: (([String: Any]) -> Void)?
    var onFailure: ((DesktopFailureKind) -> Void)?

    func open() async throws {
        // Simulate fast LAN delivering mobile.approval + mobile.ready BEFORE awaitReady() is called.
        onFrame?([
            "type": "mobile.approval",
            "code": "123456",
            "expiresAt": Int64(Date().timeIntervalSince1970) + 120,
        ])
        onFrame?([
            "type": "mobile.ready",
            "protocol": "pebrel.mobile.relay",
            "version": 1,
            "capabilities": ["snapshot": true, "input": true],
            "host": ["os": "linux"],
        ])
    }

    func send(_ frame: [String: Any]) async throws {
        if let id = frame["id"] as? String, (frame["method"] as? String) == "events.subscribe" {
            onFrame?([
                "id": id,
                "ok": true,
                "result": [
                    "snapshot": [
                        "process_id": 42,
                        "revision": 1,
                        "mobile_policy": ["allow_input": true, "notifications": true],
                        "windows": [],
                    ],
                ],
            ])
        }
    }

    func readyTimeoutFailure() -> DesktopFailureKind { .timeout }
    func close() {}
}
