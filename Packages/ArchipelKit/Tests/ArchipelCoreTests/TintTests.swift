import Foundation
import Testing
@testable import ArchipelCore

struct TintTests {
    private struct Box: Codable, Equatable { var tint: Tint }

    @Test func presetsStillSaveAsTheirName() throws {
        let json = String(decoding: try JSONEncoder().encode(Box(tint: .teal)), as: UTF8.self)
        #expect(json == #"{"tint":"teal"}"#)
        #expect(try JSONDecoder().decode(Box.self, from: Data(#"{"tint":"gray"}"#.utf8)).tint == .gray)
    }

    @Test func customColorsRoundTripAsHex() throws {
        let box = Box(tint: .custom(red: 0x12, green: 0xAB, blue: 0xFF))
        let data = try JSONEncoder().encode(box)
        #expect(String(decoding: data, as: UTF8.self) == ##"{"tint":"#12ABFF"}"##)
        #expect(try JSONDecoder().decode(Box.self, from: data) == box)
    }

    @Test(arguments: ["", "#12AB", "#12ABFFF", "12ABFF0", "#GGGGGG", "magenta"])
    func unknownValuesFailToDecode(_ value: String) {
        #expect(Tint(storedValue: value) == nil)
    }
}
