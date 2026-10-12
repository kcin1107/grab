import Foundation
import Testing
@testable import Grab

struct LinksTests {
    @Test func validatedAcceptsHttpAndHttps() {
        #expect(Links.validated("https://example.com/watch?v=1") == "https://example.com/watch?v=1")
        #expect(Links.validated("  http://example.com  \n") == "http://example.com")
        #expect(Links.validated("HTTPS://EXAMPLE.COM") == "HTTPS://EXAMPLE.COM")
    }

    @Test func validatedRejectsOtherSchemesAndGarbage() {
        #expect(Links.validated("ftp://example.com/file") == nil)
        #expect(Links.validated("file:///etc/passwd") == nil)
        #expect(Links.validated("javascript:alert(1)") == nil)
        #expect(Links.validated("https://") == nil)
        #expect(Links.validated("not a link") == nil)
        #expect(Links.validated("") == nil)
    }

    @Test func validatedAcceptsMusicLinks() {
        #expect(Links.validated("https://open.spotify.com/track/abc123") != nil)
        #expect(Links.validated("spotify:track:abc123") != nil)
        #expect(Links.validated("https://music.apple.com/us/album/name/123") != nil)
    }

    @Test func extractFindsSeveralLinksInText() {
        let text = """
        Look at https://example.com/a and also
        http://example.org/b, then https://example.com/a again.
        """
        #expect(Links.extract(fromText: text) == ["https://example.com/a", "http://example.org/b"])
    }

    @Test func extractIgnoresTextWithoutLinks() {
        #expect(Links.extract(fromText: "nothing to see here").isEmpty)
    }

    @Test func spotifyHostCheck() {
        #expect(Spotify.isSpotify("https://spotify.com/track/1"))
        #expect(Spotify.isSpotify("https://open.spotify.com/track/1"))
        #expect(!Spotify.isSpotify("https://evilspotify.com/track/1"))
        #expect(!Spotify.isSpotify("https://spotify.com.evil.com/track/1"))
    }

    @Test func appleMusicHostCheck() {
        #expect(AppleMusic.isAppleMusic("https://music.apple.com/us/album/x/1"))
        #expect(!AppleMusic.isAppleMusic("https://evilmusic.apple.com.example.com/us/album/x/1"))
        #expect(!AppleMusic.isAppleMusic("https://apple.com/us/album/x/1"))
    }

    @Test func identityIgnoresLinkStyleAndTracking() {
        #expect(Links.identity("https://youtu.be/abc?si=xyz") == Links.identity("https://www.youtube.com/watch?v=abc&feature=share"))
    }
}
