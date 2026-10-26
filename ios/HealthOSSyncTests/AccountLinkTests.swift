import XCTest
@testable import HealthOSSync

/// The way in (Auth/, SignInView, JoinView): invite codes and reset links as the server reads them (server/auth.ts
/// normalizeToken and CODE_ALPHABET), the shape check that keeps a mistyped code from counting toward the household's
/// sign-in lockout, the link check's outcomes, and the words against src/pages/Login.tsx.
@MainActor
final class AccountLinkTests: XCTestCase {
    /// A file of the web app, next to the iPhone app in the repository.
    private func web(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("\(path) isn't next to the app") }
        return text
    }

    /// A reset link's token as the server makes them: 24 random bytes, base64url.
    private let resetToken = "q3X_9kP-2mZbV7aLr0TtYw4uNcEhGfDs"

    // MARK: Against the server's own rules

    func testTheCodeAlphabetAndThePasswordLengthAreTheServers() throws {
        let auth = try web("server/auth.ts")
        let alphabet = try XCTUnwrap(auth.firstMatch(of: /const CODE_ALPHABET = '([A-Z0-9]+)'/)?.output.1)
        XCTAssertEqual(AccountLink.codeAlphabet, String(alphabet))
        XCTAssertEqual(AccountLink.codeAlphabet.count, 31)
        for lookAlike in "01ILO" { XCTAssertFalse(AccountLink.codeAlphabet.contains(lookAlike), "\(lookAlike)") }
        XCTAssertTrue(auth.contains("MIN_PASSWORD"))
        XCTAssertTrue(try web("src/pages/Login.tsx").contains("const MIN_PASSWORD = \(AccountLink.minPassword);"))
        XCTAssertTrue(auth.contains("req.body.name.trim().slice(0, \(AccountLink.maxName))"))
        XCTAssertTrue(auth.contains("randomBytes(24).toString('base64url')"), "reset links are 32 characters, well over minLinkToken")
        XCTAssertGreaterThan(32, AccountLink.minLinkToken)
    }

    /// normalizeToken: a code in any case, with dashes or spaces, comes back canonical; a whole link loses everything up
    /// to its token; anything else is kept as given (link tokens are case-sensitive).
    func testWhatIsPastedIsReadAsTheServerReadsIt() {
        XCTAssertEqual(AccountLink.parse("  abcd-efgh \n"), PastedLink(kind: nil, token: "ABCDEFGH"))
        XCTAssertEqual(AccountLink.parse("ABCD EFGH"), PastedLink(kind: nil, token: "ABCDEFGH"))
        XCTAssertEqual(AccountLink.parse("https://health.example.test/#/invite/ABCDEFGH"), PastedLink(kind: .invite, token: "ABCDEFGH"))
        XCTAssertEqual(AccountLink.parse("https://health.example.test/#/invite/abcd-efgh?from=admin"), PastedLink(kind: .invite, token: "ABCDEFGH"))
        XCTAssertEqual(AccountLink.parse("https://health.example.test/#/reset/\(resetToken)"), PastedLink(kind: .reset, token: resetToken))
        XCTAssertEqual(AccountLink.parse("http://192.168.1.4:8787/#/reset/\(resetToken)/ "), PastedLink(kind: .reset, token: resetToken))
        // An older invite link's long token keeps its case.
        XCTAssertEqual(AccountLink.parse("…/#/invite/aB3-x_Yz9QmmKKpp2rT0vWx8"), PastedLink(kind: .invite, token: "aB3-x_Yz9QmmKKpp2rT0vWx8"))
        XCTAssertEqual(AccountLink.parse(resetToken), PastedLink(kind: nil, token: resetToken))
        XCTAssertEqual(AccountLink.parse("   "), PastedLink(kind: nil, token: ""))
        XCTAssertFalse(AccountLink.filled(" \n"))
        XCTAssertTrue(AccountLink.filled("A"))
    }

    /// A failed check counts toward the lockout everyone on one network shares (8 failures, 15 minutes), so what can't be
    /// a code or a link is never sent.
    func testOnlyACodeOrALinkTheServerCouldHaveMadeIsSent() {
        // The web's own check (cleanCode, [A-Z2-9]{8}) lets these through, and the server would count each as a failure.
        for typo in ["ABCD-EFGO", "abcd-efgi", "ABCD-EFG1", "ABCD-EFG0", "LLLL-LLLL"] {
            XCTAssertFalse(AccountLink.plausible(AccountLink.parse(typo).token, as: .invite), typo)
        }
        for short in ["ABC", "ABCD-EFG", "ABCD-EFGHJ", "https://x.test/#/invite/", "hello there"] {
            XCTAssertFalse(AccountLink.plausible(AccountLink.parse(short).token, as: .invite), short)
        }
        XCTAssertTrue(AccountLink.plausible(AccountLink.parse("abcd efgh").token, as: .invite))
        XCTAssertTrue(AccountLink.plausible(AccountLink.parse("Z2Z3-Z4Z5").token, as: .invite))
        XCTAssertTrue(AccountLink.plausible(resetToken, as: .invite), "an older invite link's long token")
        // A reset is only ever a long link.
        XCTAssertTrue(AccountLink.plausible(resetToken, as: .reset))
        XCTAssertFalse(AccountLink.plausible("ABCDEFGH", as: .reset))
        XCTAssertFalse(AccountLink.plausible(resetToken + "!", as: .reset))
        XCTAssertFalse(AccountLink.plausible("short_token-x", as: .reset))
    }

    func testTheCodeStepOpensThePageThePastedLinkNames() throws {
        switch AccountLink.entered("abcd-efgh", on: .invite) {
        case .success(let (kind, token)): XCTAssertEqual(kind, .invite); XCTAssertEqual(token, "ABCDEFGH")
        case .failure: XCTFail("a code")
        }
        // A reset link pasted where a code goes opens the reset page, and an invite link where a reset link goes the
        // invite's.
        switch AccountLink.entered("https://h.example.test/#/reset/\(resetToken)", on: .invite) {
        case .success(let (kind, token)): XCTAssertEqual(kind, .reset); XCTAssertEqual(token, resetToken)
        case .failure: XCTFail("a reset link")
        }
        switch AccountLink.entered("https://h.example.test/#/invite/ABCDEFGH", on: .reset) {
        case .success(let (kind, _)): XCTAssertEqual(kind, .invite)
        case .failure: XCTFail("an invite link")
        }
        // A bare code on the reset step can't be one: the server's own words, without asking it.
        switch AccountLink.entered("ABCDEFGH", on: .reset) {
        case .success: XCTFail("a code isn't a reset link")
        case .failure(let error): XCTAssertEqual(error.localizedDescription, "This code or link is invalid, expired or already used.")
        }
        switch AccountLink.entered("ABCD-EFGO", on: .invite) {
        case .success: XCTFail("O isn't in a code")
        case .failure(let error): XCTAssertEqual(error.localizedDescription, AccountLink.invalid)
        }
        XCTAssertTrue(try web("server/auth.ts").contains("'\(AccountLink.invalid)'"))
    }

    // MARK: The link's check (AccountLinkPage)

    func testTheLinksCheckComesOutAsTheWebShowsIt() async throws {
        let invite = await AccountLink.check("ABCDEFGH", kind: .invite) { _ in LinkCheck(kind: .invite, email: "sam@example.test") }
        XCTAssertEqual(invite, .ok(email: "sam@example.test"))
        // A reset link opened as an invite (or the other way round): the web's words, not the form.
        let wrong = await AccountLink.check(resetToken, kind: .invite) { _ in LinkCheck(kind: .reset, email: nil) }
        XCTAssertEqual(wrong, .bad("This link is invalid, expired or already used."))
        XCTAssertTrue(try web("src/pages/Login.tsx").contains("'\(AccountLink.wrongKind)'"))
        // The server's 404, in its words (APIClient passes /auth/link's 4xx through).
        let used = await AccountLink.check("ABCDEFGH", kind: .invite) { _ in
            throw APIClient.error(status: 404, message: "This code or link is invalid, expired or already used.", path: "/auth/link")
        }
        XCTAssertEqual(used, .bad("This code or link is invalid, expired or already used."))
        let locked = await AccountLink.check("ABCDEFGH", kind: .invite) { _ in
            throw APIClient.error(status: 429, message: "Too many attempts. Try again after 10:15:00 PM.", path: "/auth/link")
        }
        XCTAssertEqual(locked, .bad("Too many attempts. Try again after 10:15:00 PM."))
        // A server older than the check, asked while signed out: its session gate answers 401. On to the form.
        let older = await AccountLink.check("ABCDEFGH", kind: .invite) { _ in
            throw APIClient.error(status: 401, message: "Sign in required", path: "/auth/link")
        }
        XCTAssertEqual(older, .unchecked)
    }

    func testTheCheckDecodesAnEmailOnlyWhenTheInviteIsForOne() throws {
        let locked = try JSONDecoder().decode(LinkCheck.self, from: Data(#"{"kind":"invite","email":"sam@example.test"}"#.utf8))
        XCTAssertEqual(locked, LinkCheck(kind: .invite, email: "sam@example.test"))
        XCTAssertNil(try JSONDecoder().decode(LinkCheck.self, from: Data(#"{"kind":"reset","email":null}"#.utf8)).email)
        XCTAssertNil(try JSONDecoder().decode(LinkCheck.self, from: Data(#"{"kind":"invite"}"#.utf8)).email)
        XCTAssertNil(try JSONDecoder().decode(LinkCheck.self, from: Data(#"{"kind":"invite","email":""}"#.utf8)).email)
        XCTAssertThrowsError(try JSONDecoder().decode(LinkCheck.self, from: Data(#"{"kind":"magic"}"#.utf8)))
    }

    func testTheInvitesLedeNamesItsCodeAsItsReadAloud() throws {
        XCTAssertEqual(AccountLink.codeLabel("ABCDEFGH"), "ABCD-EFGH")
        XCTAssertEqual(AccountLink.codeLabel(resetToken), "accepted")
        let lede = AccountLink.inviteLede("ABCDEFGH")
        XCTAssertTrue(lede.hasPrefix("Invite code ABCD-EFGH. Your full dashboard is private to you."))
        // The web's sentence after its ${…}.
        let login = try web("src/pages/Login.tsx")
        let after = try XCTUnwrap(login.firstMatch(of: /: 'accepted'\}\. (Your full dashboard[^`]*)`/)?.output.1)
        XCTAssertTrue(lede.hasSuffix(String(after)))
    }

    // MARK: Words against Login.tsx

    func testTheWayInSaysWhatTheWebSays() throws {
        let login = try web("src/pages/Login.tsx")
        let folded = login.replacing(/\s+/, with: " ")
        let quoted = [
            SignInWords.welcomeBack, SignInWords.welcome, SignInWords.signInTitle, SignInWords.setupTitle, SignInWords.setupLede,
            SignInWords.misconfigured, SignInWords.haveInvite, SignInWords.forgot, SignInWords.signIn, SignInWords.signingIn,
            SignInWords.joinEyebrow, SignInWords.joinTitle, SignInWords.joinLede, SignInWords.codeLabel, SignInWords.backToSignIn,
            SignInWords.continueButton, SignInWords.resetEyebrow, SignInWords.createTitle, SignInWords.resetTitle, SignInWords.resetLede,
            SignInWords.checking, SignInWords.newLink, SignInWords.goToSignIn, SignInWords.passwordsDiffer, SignInWords.nextSteps,
            SignInWords.createAccount, SignInWords.setPassword, SignInWords.saving,
        ]
        for words in quoted { XCTAssertTrue(folded.contains(words), words) }
        XCTAssertTrue(folded.contains("At least {MIN_PASSWORD} characters."))
        XCTAssertEqual(SignInWords.passwordHint, "At least 10 characters.")
        // The iPhone's own lines aren't the web's, and don't pretend to be.
        for own in [SignInWords.haveResetLink, SignInWords.resetLinkTitle, SignInWords.resetLinkLede] { XCTAssertFalse(folded.contains(own), own) }
    }
}
