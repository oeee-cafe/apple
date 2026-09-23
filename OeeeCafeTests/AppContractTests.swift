import Foundation
import Testing
@testable import OeeeCafe

/// The app against the site's contract (appContract.json, a copy of
/// frontend/shared/appContract.json in oeee-cafe/web, refreshed by
/// scripts/sync-app-contract.sh). The site's own test fails when its pages stop matching
/// that file; this fails when the app does.
struct AppContractTests {
    // MARK: - Messages

    /// Every message the page sends, as the site captured it, read by the app's own parser
    /// (`SiteMessage(body:)`, what SiteBridge hears) into what the example says.
    @Test func everyMessageThePageSendsParsesAsItSays() throws {
        let messages = try Fixture.messages()
        #expect(!messages.isEmpty)
        for (type, examples) in messages {
            #expect(!examples.isEmpty, "no example of \(type)")
            // One example the test cannot read is recorded, and the rest are still checked.
            for example in examples {
                do {
                    let text = try Fixture.string(example)
                    let expected = try Self.expected(type, example)
                    #expect(SiteMessage(body: text) == expected, "\(text)")
                } catch is ExpectationFailedError {
                    // A field the example lacks, already recorded by `#require`.
                } catch {
                    Issue.record(error, "\(type): \(example)")
                }
            }
        }
    }

    #if os(iOS)
    /// A drawing a finger lands on, as the page says it, is one the long press's menu opens
    /// on (DrawingMenu).
    @Test func aPressedDrawingOpensTheMenu() throws {
        let examples = try #require(try Fixture.messages()["pressed"])
        var drawings = 0
        for example in examples {
            guard case .pressed(let pressed?) = SiteMessage(body: try Fixture.string(example)) else { continue }
            drawings += 1
            let drawing = try #require(DrawingMenu.drawing(from: pressed, referrer: nil))
            #expect(drawing.url.absoluteString == pressed.src)
            #expect(drawing.link?.absoluteString == (pressed.link.isEmpty ? nil : pressed.link))
        }
        #expect(drawings > 0, "the contract has no pressed example with a drawing")
    }
    #endif

    /// Each type the app reads is still in the contract, so a type renamed on the site does
    /// not simply stop being heard.
    @Test func everyTypeTheAppReadsIsOneThePageSends() throws {
        let sent = Set(try Fixture.messages().keys)
        for type in Self.handled {
            #expect(sent.contains(type), "the page no longer sends \(type)")
        }
    }

    /// What the page would say under another version of the contract, or not as a string,
    /// is not heard at all.
    @Test func anotherVersionOrAnotherShapeIsNotHeard() throws {
        var example = try #require(try Fixture.messages()["unread"]?.first)
        example["v"] = 2
        #expect(SiteMessage(body: try Fixture.string(example)) == nil)
        example["v"] = 1
        #expect(SiteMessage(body: example) == nil)
        #expect(SiteMessage(body: "not json") == nil)
    }

    /// The types this app reads; the rest are other apps' (`browse`, `share`, `download`,
    /// `caption`) and are ignored.
    private static let handled: Set<String> = [
        "page", "unread", "theme", "words", "haptic", "pressed", "painter", "prices",
        "purchase", "restore", "signIn", "window",
    ]
    private static let ignored: Set<String> = ["browse", "share", "download", "caption"]

    /// What the app should make of `example`, worked out from the example itself rather than
    /// by the parser under test.
    private static func expected(_ type: String, _ example: [String: Any]) throws -> SiteMessage? {
        if ignored.contains(type) { return nil }
        switch type {
        case "page":
            return .page(SiteMessage.Page(
                path: try field(example, "path"),
                signedIn: example["signedIn"] as? Bool,
                painting: try field(example, "painting"),
                refreshable: try field(example, "refreshable")
            ))
        case "unread":
            return .unread(count: try field(example, "count"))
        case "theme":
            return .theme(SiteMessage.Theme(
                choice: try field(example, "choice"),
                ground: example["ground"] as? String
            ))
        case "words":
            var words = SiteMessage.Words()
            words.leaveTitle = try field(example, "leaveTitle")
            words.leaveBody = try field(example, "leaveBody")
            words.leave = try field(example, "leave")
            words.stay = try field(example, "stay")
            words.saveImage = try field(example, "saveImage")
            words.copyImage = try field(example, "copyImage")
            words.share = try field(example, "share")
            words.copyLink = try field(example, "copyLink")
            return .words(words)
        case "haptic":
            return .haptic(name: try field(example, "name"))
        case "pressed":
            guard let drawing = example["drawing"] as? [String: Any] else { return .pressed(nil) }
            return .pressed(SiteMessage.Drawing(
                src: try field(drawing, "src"),
                link: try field(drawing, "link"),
                width: try field(drawing, "width"),
                height: try field(drawing, "height")
            ))
        case "painter":
            #expect(example["state"] as? String == "ready")
            return .painterReady
        case "prices":
            return .prices(products: try field(example, "products"))
        case "purchase":
            return .purchase(product: try field(example, "product"))
        case "restore":
            return .restore
        case "signIn":
            return .signIn(provider: try field(example, "provider"), nonce: example["nonce"] as? String)
        case "window":
            return .window(action: try field(example, "action"))
        default:
            Issue.record("""
                The contract has a message this test does not know, \(type): read it in \
                SiteMessage, or add it to `ignored` if this app has no use for it.
                """)
            return nil
        }
    }

    private static func field<T>(_ object: [String: Any], _ key: String) throws -> T {
        try #require(object[key] as? T, "\(key) in \(object)")
    }

    // MARK: - The user agent

    /// Each build's mark is one the site reads as that app selling through the App Store,
    /// and none of the agents the site refuses, or reads as something else, ends with it.
    @Test(arguments: [("ios", UserAgent.ios), ("macos", UserAgent.macos)])
    func theUserAgentMarksTheApp(platform: String, mark: String) throws {
        let agents = try Fixture.contract().userAgents
        let marked = agents.filter { $0.agent.hasSuffix(" " + mark) }
        #expect(marked.contains { $0.app == platform && $0.store == "apple" },
                "no agent in the contract ends with \(mark) and is read as \(platform) on the App Store")
        for agent in marked {
            #expect(agent.app == platform && agent.store == "apple", "\(agent.agent)")
        }
    }

    // MARK: - Leaving

    @Test func wouldLoseWorkIsAskedInTheContractsWords() throws {
        #expect(Scripts.wouldLoseWork == (try Fixture.contract().scripts["wouldLoseWork"]))
    }

    @Test func leavingIsSaidInTheContractsWords() throws {
        let leaving = try #require(try Fixture.contract().scripts["leaving"])
        #expect(Scripts.leavingExpression == leaving)
        #expect(Scripts.leaving.contains(leaving))
        #expect(Scripts.leaving.hasPrefix("await "))
    }

    // MARK: - What the app calls

    /// Every `window.oeeeApp` member the app's scripts reach for is one the site lists. A
    /// namespace on the way to one (`window.oeeeApp.store` before `.prices`) counts.
    @Test func everyMemberTheAppCallsIsInTheContract() throws {
        let members = Set(try Fixture.contract().members)
        let pattern = try NSRegularExpression(
            pattern: #"window\.oeeeApp\.([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"#
        )
        var reached: Set<String> = []
        for script in Scripts.all {
            let range = NSRange(script.startIndex..., in: script)
            for match in pattern.matches(in: script, range: range) {
                if let path = Range(match.range(at: 1), in: script) {
                    reached.insert(String(script[path]))
                }
            }
        }
        #expect(!reached.isEmpty)
        for path in reached {
            let known = members.contains(path) || members.contains { $0.hasPrefix(path + ".") }
            #expect(known, "window.oeeeApp.\(path) is not in the contract's members")
        }
    }

    /// Every command the Mac's menu bar sends is one the site's `oeeeApp.command` takes.
    @Test func everyCommandTheMenuSendsIsInTheContract() throws {
        let commands = Set(try Fixture.contract().commands)
        for command in SiteCommand.allCases {
            #expect(commands.contains(command.rawValue), "\(command.rawValue) is not a site command")
        }
    }
}

/// appContract.json, from the test bundle.
private enum Fixture {
    struct Contract: Decodable {
        struct Agent: Decodable {
            let agent: String
            let app: String?
            let form: String?
            let store: String?
        }

        let userAgents: [Agent]
        let members: [String]
        let commands: [String]
        let scripts: [String: String]
    }

    private final class Marker {}

    static func data() throws -> Data {
        let url = try #require(
            Bundle(for: Marker.self).url(forResource: "appContract", withExtension: "json"),
            "appContract.json is not in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    static func contract() throws -> Contract {
        try JSONDecoder().decode(Contract.self, from: data())
    }

    /// `messages`: each type, and its examples as the page sent them.
    static func messages() throws -> [String: [[String: Any]]] {
        let root = try #require(try JSONSerialization.jsonObject(with: data()) as? [String: Any])
        return try #require(root["messages"] as? [String: [[String: Any]]])
    }

    /// An example as the JSON string the page posts.
    static func string(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }
}
