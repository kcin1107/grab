import Foundation
import Testing
@testable import Grab

@MainActor
struct SearchTests {
    @Test func newQueryKeepsSheetIdentityAndClearsPreviousResults() {
        let session = SearchSession(query: "original", kind: .videos)
        let sheetID = session.id
        let requestID = session.requestID
        session.phase = .ready
        session.results = [result]
        session.added = [result.id]

        #expect(session.restart(query: "  new query\n", kind: .music))

        #expect(session.id == sheetID)
        #expect(session.requestID != requestID)
        #expect(session.query == "new query")
        #expect(session.kind == .music)
        #expect(session.phase == .loading)
        #expect(session.results.isEmpty)
        #expect(session.added.isEmpty)
    }

    @Test func retryCreatesAnotherRequestForSameQueryAndKind() {
        let session = SearchSession(query: "song", kind: .music)
        let sheetID = session.id
        let failedRequestID = session.requestID
        session.phase = .failed

        #expect(session.restart(query: session.query, kind: session.kind))

        #expect(session.id == sheetID)
        #expect(session.requestID != failedRequestID)
        #expect(session.query == "song")
        #expect(session.kind == .music)
        #expect(session.phase == .loading)
    }

    @Test func blankQueryLeavesCurrentSearchIntact() {
        let session = SearchSession(query: "original", kind: .videos)
        let requestID = session.requestID
        session.phase = .ready
        session.results = [result]
        session.added = [result.id]

        #expect(!session.restart(query: " \n\t ", kind: .music))

        #expect(session.requestID == requestID)
        #expect(session.query == "original")
        #expect(session.kind == .videos)
        #expect(session.phase == .ready)
        #expect(session.results == [result])
        #expect(session.added == [result.id])
    }

    private var result: SearchResult {
        SearchResult(id: "video", url: "https://www.youtube.com/watch?v=video",
                     title: "Video", duration: nil, views: nil, thumbnail: nil)
    }
}
