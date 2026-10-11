import Foundation
import Testing
@testable import OeeeCafe

/// Only the site's own pages and Google's sign-in page, over https, are opened in the browser
/// a sign-in is handed to: the page says where to go, and this is what keeps it from sending
/// the app elsewhere.
struct BrowserSignInTests {
    @Test(arguments: [
        "https://oeee.cafe/auth/google?handoff=I",
        "https://oeee.cafe/",
        "HTTPS://oeee.cafe/auth/google",
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=C&state=S&nonce=N",
    ])
    func theSitesOwnPageOrGooglesSignInIsOpened(url: String) {
        #expect(BrowserSignIn.url(url) != nil)
    }

    @Test(arguments: [
        "http://oeee.cafe/auth/google",
        "http://accounts.google.com/o/oauth2/v2/auth",
        "https://accounts.google.com/",
        "https://accounts.google.com/o/oauth2/v2/authx",
        "https://accounts.google.com.example/o/oauth2/v2/auth",
        "https://accounts.google.com@evil.example/o/oauth2/v2/auth",
        "https://user@accounts.google.com/o/oauth2/v2/auth",
        "https://accounts.google.com:8443/o/oauth2/v2/auth",
        "https://oeee.cafe.example.com/auth/google",
        "https://evil.example/?https://oeee.cafe/",
        "https://oeee.cafe@evil.example/",
        "oeee-cafe://handoff/done",
        "javascript:alert(1)",
        "/auth/google",
        "",
    ])
    func anyOtherPageIsNot(url: String) {
        #expect(BrowserSignIn.url(url) == nil)
    }

    // MARK: - The code the browser brings back

    @Test func theCodeTheCallbackBringsIsTaken() throws {
        let callback = try #require(URL(string: "oeee-cafe://handoff/done?code=\(handoffCode)"))
        #expect(BrowserSignIn.handoffCode(in: callback) == handoffCode)
    }

    /// A code goes into a script, so only exactly 64 lowercase hex digits are one: not upper
    /// case, not one digit short or over, not anything that is not hex, and not none.
    @Test(arguments: [
        "oeee-cafe://handoff/done",
        "oeee-cafe://handoff/done?code=",
        "oeee-cafe://handoff/done?other=\(handoffCode)",
        "oeee-cafe://handoff/done?code=\(handoffCode.uppercased())",
        "oeee-cafe://handoff/done?code=\(handoffCode.dropLast())",
        "oeee-cafe://handoff/done?code=\(handoffCode)0",
        "oeee-cafe://handoff/done?code=\(handoffCode.dropLast())g",
        "oeee-cafe://handoff/done?code=\(handoffCode.dropLast(2))%22)",
        "oeee-cafe://handoff/done?code=\(handoffCode)&code=\(handoffCode)",
    ])
    func anythingElseIsNot(callback: String) throws {
        let url = try #require(URL(string: callback))
        #expect(BrowserSignIn.handoffCode(in: url) == nil)
    }

    @Test func theCodeIsHandedToThePageQuoted() {
        let script = Scripts.signInResume(code: handoffCode)
        #expect(script.contains("window.oeeeApp.signIn.resume(\"\(handoffCode)\");"))
    }

    /// Without a code -- or with one that is not -- the page is asked as it was before the
    /// site sent codes.
    @Test func withoutACodeThePageResumesAsBefore() {
        let before = """
            window.oeeeApp && window.oeeeApp.signIn && window.oeeeApp.signIn.resume \
            && window.oeeeApp.signIn.resume();
            """
        #expect(Scripts.signInResume(code: nil) == before)
        #expect(Scripts.signInResume(code: handoffCode.uppercased()) == before)
        #expect(Scripts.signInResume(code: "\"); alert(1); (\"") == before)
    }
}

/// A handoff's code as the site makes them: 64 lowercase hex digits.
nonisolated private let handoffCode = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
