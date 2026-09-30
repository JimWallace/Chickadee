import Foundation
import Testing

@testable import APIServer

@Suite struct CourseYearOptionsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // September 2026
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    @Test func defaultsToCurrentYearInsideAWindow() {
        let options = CourseTermForm.yearOptions(selected: nil, now: now, calendar: calendar)
        #expect(options.map(\.value) == ["2025", "2026", "2027", "2028"])
        #expect(options.filter(\.selected).map(\.value) == ["2026"])
    }

    @Test func marksTheGivenYear() {
        let options = CourseTermForm.yearOptions(selected: 2028, now: now, calendar: calendar)
        #expect(options.filter(\.selected).map(\.value) == ["2028"])
    }

    @Test func keepsAnOutOfWindowYear() {
        let options = CourseTermForm.yearOptions(selected: 2019, now: now, calendar: calendar)
        #expect(options.map(\.value) == ["2019", "2025", "2026", "2027", "2028"])
        #expect(options.filter(\.selected).map(\.value) == ["2019"])
    }
}
