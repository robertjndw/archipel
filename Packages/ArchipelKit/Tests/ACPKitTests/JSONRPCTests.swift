@testable import ACPKit
import Foundation
import Testing

struct LineFramerTests {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func messageSplitAcrossChunks() throws {
        var framer = JSONRPCLineFramer()
        #expect(try framer.append(Data(#"{"a":"#.utf8)).isEmpty)
        #expect(try framer.append(Data(#"1"#.utf8)).isEmpty)
        #expect(strings(try framer.append(Data("}\n".utf8))) == [#"{"a":1}"#])
        #expect(framer.pendingByteCount == 0)
    }

    @Test func byteByByte() throws {
        var framer = JSONRPCLineFramer()
        var lines: [String] = []
        for byte in Data("{\"x\":\"é\u{2028}\"}\n{\"y\":2}\n".utf8) {
            lines += strings(try framer.append(Data([byte])))
        }
        #expect(lines == ["{\"x\":\"é\u{2028}\"}", #"{"y":2}"#])
    }

    @Test func severalMessagesInOneChunk() throws {
        var framer = JSONRPCLineFramer()
        let lines = try framer.append(Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8))
        #expect(strings(lines) == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    }

    @Test func trailingPartialLineWaitsForItsNewline() throws {
        var framer = JSONRPCLineFramer()
        #expect(strings(try framer.append(Data("{\"a\":1}\n{\"b\"".utf8))) == [#"{"a":1}"#])
        #expect(framer.pendingByteCount == 4)
        #expect(strings(try framer.append(Data(":2}\n".utf8))) == [#"{"b":2}"#])
    }

    @Test func crlfAndBlankLines() throws {
        var framer = JSONRPCLineFramer()
        let lines = try framer.append(Data("\n\r\n{\"a\":1}\r\n   \n\t\r\n{\"b\":2}\n".utf8))
        #expect(strings(lines) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func lineSeparatorsInsideStringsSurvive() throws {
        var framer = JSONRPCLineFramer()
        let line = "{\"text\":\"one\u{2028}two\u{2029}three\u{85}four\"}"
        let lines = try framer.append(Data((line + "\n").utf8))
        #expect(strings(lines) == [line])
        let message = try JSONRPCMessage.decode(Data(("{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":" + line + "}").utf8))
        #expect(message == .notification(method: "x", params: ["text": "one\u{2028}two\u{2029}three\u{85}four"]))
    }

    @Test func veryLongLine() throws {
        var framer = JSONRPCLineFramer()
        let text = String(repeating: "abcdefgh", count: 1 << 18)
        let line = Data("{\"t\":\"\(text)\"}\n".utf8)
        var lines: [Data] = []
        var offset = 0
        while offset < line.count {
            let end = min(offset + 4093, line.count)
            lines += try framer.append(line[offset..<end])
            offset = end
        }
        #expect(lines.count == 1)
        #expect(lines.first?.count == line.count - 1)
    }

    @Test func lineOverTheLimitThrows() throws {
        var framer = JSONRPCLineFramer(maximumLineLength: 16)
        #expect(try framer.append(Data("{\"a\":1}\n".utf8)).count == 1)
        #expect(throws: JSONRPCLineFramer.LineTooLong(limit: 16)) {
            try framer.append(Data(String(repeating: "x", count: 17).utf8))
        }
    }
}

struct JSONRPCMessageTests {
    @Test func classifiesRequestsNotificationsAndResponses() throws {
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":3,"method":"m","params":{"a":1}}"#.utf8))
            == .request(id: .int(3), method: "m", params: ["a": 1]))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":"x-1","method":"m"}"#.utf8))
            == .request(id: .string("x-1"), method: "m", params: nil))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","method":"n","params":[1,2]}"#.utf8))
            == .notification(method: "n", params: [1, 2]))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":null,"method":"n"}"#.utf8))
            == .notification(method: "n", params: nil))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true}}"#.utf8))
            == .response(id: .int(4), result: .success(["ok": true])))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":5,"result":null}"#.utf8))
            == .response(id: .int(5), result: .success(.null)))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":6,"error":{"code":-32000,"message":"Auth required","data":{"x":1}}}"#.utf8))
            == .response(id: .int(6), result: .failure(JSONRPCError(code: -32000, message: "Auth required", data: ["x": 1]))))
        #expect(try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
            == .response(id: nil, result: .failure(JSONRPCError(code: -32700, message: "Parse error"))))
    }

    @Test func rejectsWhatIsNotJSONRPC() {
        #expect(throws: (any Error).self) { try JSONRPCMessage.decode(Data("hello".utf8)) }
        #expect(throws: (any Error).self) { try JSONRPCMessage.decode(Data(#"{"jsonrpc":"2.0"}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONRPCMessage.decode(Data("[1,2]".utf8)) }
    }

    @Test func encodesOnOneLineWithoutEscapedSlashes() throws {
        let message = JSONRPCMessage.request(
            id: .int(1),
            method: "session/prompt",
            params: ["text": "line one\nline two\u{2028}", "uri": "file:///repo/a.swift"]
        )
        let data = try message.encoded()
        #expect(!data.contains(0x0A))
        #expect(!data.contains(0x0D))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("file:///repo/a.swift"))
        #expect(!text.contains(#"\/"#))
        #expect(try JSONRPCMessage.decode(data) == message)
    }

    @Test func responsesKeepANullId() throws {
        let text = String(decoding: try JSONRPCMessage.response(id: nil, result: .failure(JSONRPCError(code: -32700, message: "x"))).encoded(), as: UTF8.self)
        #expect(text.contains(#""id":null"#))
    }

    @Test func requestIds() throws {
        #expect(try decode(JSONRPCID.self, "7") == .int(7))
        #expect(try decode(JSONRPCID.self, #""abc""#) == .string("abc"))
        #expect(try decode(JSONRPCID.self, "7.0") == .int(7))
        #expect(throws: (any Error).self) { try decode(JSONRPCID.self, "true") }
        #expect(try jsonString(JSONRPCID.int(3)) == "3")
        #expect(try jsonString(JSONRPCID.string("a")) == #""a""#)
    }
}

struct JSONValueTests {
    @Test func roundTripsEveryKind() throws {
        let json = #"{"n":null,"b":true,"i":42,"d":1.5,"s":"x/y","a":[1,"two",false],"o":{"k":[]}}"#
        let value = try decode(JSONValue.self, json)
        #expect(value["n"] == .null)
        #expect(value["b"]?.boolValue == true)
        #expect(value["i"]?.intValue == 42)
        #expect(value["d"]?.doubleValue == 1.5)
        #expect(value["d"]?.intValue == nil)
        #expect(value["s"]?.stringValue == "x/y")
        #expect(value["a"]?[1]?.stringValue == "two")
        #expect(value["a"]?[9] == nil)
        #expect(value["o"]?["k"]?.arrayValue == [])
        #expect(value["missing"] == nil)
        #expect(try decode(JSONValue.self, jsonString(value)) == value)
    }

    @Test func integersStayIntegers() throws {
        #expect(try jsonString(JSONValue.number(3)) == "3")
        #expect(try jsonString(JSONValue.number(0.25)) == "0.25")
    }

    @Test func convertsToAndFromTypes() throws {
        let value = try JSONValue(encoding: PlanEntry(content: "x", priority: .high, status: .completed))
        #expect(value == ["content": "x", "priority": "high", "status": "completed"])
        #expect(try value.decode(as: PlanEntry.self) == PlanEntry(content: "x", priority: .high, status: .completed))
    }
}
