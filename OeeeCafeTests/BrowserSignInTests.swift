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
}
