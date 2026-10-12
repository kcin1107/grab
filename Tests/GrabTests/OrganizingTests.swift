import Foundation
import Testing
@testable import Grab

struct OrganizingTests {
    @Test func folderNameHasNoSeparatorsOrLeadingDots() {
        let cleaned = Folders.sanitize("../My: Mix/Vol 1")
        #expect(!cleaned.contains("/"))
        #expect(!cleaned.contains(":"))
        #expect(!cleaned.hasPrefix("."))
        #expect(cleaned == "-My- Mix-Vol 1")
    }

    @Test func folderNameIsTrimmedAndLimited() {
        #expect(Folders.sanitize("  Mix  ") == "Mix")
        #expect(Folders.sanitize(String(repeating: "a", count: 300)).count == 100)
    }

    @Test func emptyFolderNameFallsBack() {
        #expect(!Folders.sanitize("...").isEmpty)
        #expect(!Folders.sanitize("   ").isEmpty)
    }

    @Test func customTemplateReplacesTokensAndEscapesLiterals() {
        #expect(FileNaming.customTemplate("{artist} - {title}") == "%(artist,creator,uploader,channel)s - %(track,title)s")
        #expect(FileNaming.customTemplate("{title} 100% a/b:c") == "%(track,title)s 100%% a-b-c")
        #expect(FileNaming.customTemplate("no tokens") == nil)
    }

    @Test func customPreviewHasNoSeparators() throws {
        let preview = try #require(FileNaming.preview("{title}/{year}:x"))
        #expect(preview == "Spring-2019-x.mp4")
    }
}

struct ClipRangeTests {
    @Test func parsesTimes() {
        #expect(ClipRange.parseTime("90") == .some(90))
        #expect(ClipRange.parseTime("1:30") == .some(90))
        #expect(ClipRange.parseTime("1:02:03") == .some(3723))
        #expect(ClipRange.parseTime("1:30.5") == .some(90.5))
        #expect(ClipRange.parseTime("  ") == .some(nil))
        #expect(ClipRange.parseTime("1:75") == nil)
        #expect(ClipRange.parseTime("abc") == nil)
        #expect(ClipRange.parseTime("1:2:3:4") == nil)
    }

    @Test func buildsRanges() {
        #expect(ClipRange.from(start: "0:05", end: "1:30") == ClipRange(start: 5, end: 90))
        #expect(ClipRange.from(start: "", end: "30") == ClipRange(start: 0, end: 30))
        #expect(ClipRange.from(start: "10", end: "") == ClipRange(start: 10, end: nil))
        #expect(ClipRange.from(start: "", end: "") == nil)
        #expect(ClipRange.from(start: "30", end: "10") == nil)
        #expect(ClipRange.from(start: "x", end: "10") == nil)
    }

    @Test func fileLabelIsNeverLocalized() {
        #expect(ClipRange(start: 5, end: 90).label == "0:05–1:30")
        #expect(ClipRange(start: 5, end: nil).label == "0:05–end")
        #expect(ClipRange(start: 5, end: 90).fileSuffix == " (clip 0.05–1.30)")
    }

    @Test func displayLabelUsesLocalizedEnd() {
        #expect(ClipRange(start: 5, end: nil).displayLabel == "0:05–\(String(localized: "End"))")
        #expect(ClipRange(start: 5, end: 90).displayLabel == "0:05–1:30")
    }

    @Test func sectionArgument() {
        #expect(ClipRange(start: 5, end: 90).sectionArgument == "*5-90")
        #expect(ClipRange(start: 5.5, end: nil).sectionArgument == "*5.50-inf")
    }
}
