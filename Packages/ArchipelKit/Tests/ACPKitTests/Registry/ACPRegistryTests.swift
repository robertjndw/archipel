import Foundation
import Testing

@testable import ACPKit

@Suite("ACP registry model")
struct ACPRegistryTests {
    static let sample = #"""
    {
      "version": "1.0.0",
      "extensions": [],
      "agents": [
        {
          "id": "opencode", "name": "OpenCode", "version": "2.4.1", "description": "The open source coding agent",
          "website": "https://opencode.ai", "authors": ["Anomaly"], "license": "MIT", "brand_new_field": 42,
          "distribution": {
            "binary": {
              "darwin-aarch64": {
                "archive": "https://example.com/opencode-darwin-arm64.zip", "cmd": "./opencode",
                "args": ["acp"], "sha256": "95a1000000000000000000000000000000000000000000000000000000000000"
              },
              "darwin-x86_64": {
                "archive": "https://example.com/opencode-darwin-x64.zip", "cmd": "./opencode", "args": ["acp"]
              },
              "windows-x86_64": { "cmd": "./opencode.exe" }
            }
          }
        },
        {
          "id": "codex-acp", "name": "Codex", "version": "2.10.0",
          "distribution": { "npx": { "package": "@agentclientprotocol/codex-acp@2.10.0" } }
        },
        {
          "id": "auggie", "name": "Auggie", "version": "0.37.0",
          "distribution": {
            "npx": { "package": "@augmentcode/auggie@0.37.0", "args": ["--acp"], "env": { "AUGMENT_DISABLE_AUTO_UPDATE": "1" } }
          }
        },
        {
          "id": "minion-code", "name": "Minion", "version": "0.1.44",
          "distribution": { "uvx": { "package": "minion-code@0.1.44", "args": ["acp"] } }
        },
        {
          "id": "claude-acp", "name": "Claude Agent", "version": "0.110.0",
          "distribution": {
            "binary": {
              "darwin-aarch64": { "archive": "https://example.com/claude-arm64.zip", "cmd": "./claude-agent-acp" }
            },
            "npx": { "package": "@agentclientprotocol/claude-agent-acp@0.110.0" }
          }
        },
        { "id": "broken", "name": "No distribution", "version": "1" },
        { "id": 7, "name": "Wrong types" },
        { "id": "nothing-fits", "name": "Windows only", "version": "1", "distribution": { "binary": {
            "windows-x86_64": { "archive": "https://example.com/w.zip", "cmd": "./w.exe" } } } }
      ]
    }
    """#

    func decode() throws -> ACPRegistryIndex {
        try JSONDecoder().decode(ACPRegistryIndex.self, from: Data(Self.sample.utf8))
    }

    @Test func skipsMalformedEntriesAndIgnoresUnknownFields() throws {
        let index = try decode()
        #expect(index.agents.map(\.id) == ["opencode", "codex-acp", "auggie", "minion-code", "claude-acp", "nothing-fits"])
        let opencode = try #require(index.agent(id: "opencode"))
        #expect(opencode.distribution.binary.keys.sorted() == ["darwin-aarch64", "darwin-x86_64"])
        #expect(opencode.distribution.binary["darwin-aarch64"]?.sha256 == "95a1000000000000000000000000000000000000000000000000000000000000")
        #expect(opencode.distribution.binary["darwin-x86_64"]?.sha256 == nil)
        #expect(opencode.distribution.binary["darwin-aarch64"]?.args == ["acp"])
    }

    @Test func aChecksumThatIsNotOneDropsThePlatform() throws {
        func platforms(sha256 value: String) throws -> [String] {
            let json = #"{"distribution":{"binary":{"darwin-aarch64":{"archive":"https://e.com/a.zip","cmd":"./a","sha256":\#(value)},"darwin-x86_64":{"archive":"https://e.com/b.zip","cmd":"./b"}}}}"#
            struct Entry: Decodable { var distribution: ACPRegistryDistribution }
            return try JSONDecoder().decode(Entry.self, from: Data(json.utf8)).distribution.binary.keys.sorted()
        }
        #expect(try platforms(sha256: #""\#(String(repeating: "aB", count: 32))""#) == ["darwin-aarch64", "darwin-x86_64"])
        #expect(try platforms(sha256: "null") == ["darwin-aarch64", "darwin-x86_64"])
        #expect(try platforms(sha256: #""95a1""#) == ["darwin-x86_64"])
        #expect(try platforms(sha256: #""\#(String(repeating: "z", count: 64))""#) == ["darwin-x86_64"])
        #expect(try platforms(sha256: "42") == ["darwin-x86_64"])
    }

    @Test func decodesNpxEnvAndUvx() throws {
        let index = try decode()
        let auggie = try #require(index.agent(id: "auggie")?.distribution.npx)
        #expect(auggie.args == ["--acp"])
        #expect(auggie.env == ["AUGMENT_DISABLE_AUTO_UPDATE": "1"])
        #expect(index.agent(id: "minion-code")?.distribution.uvx?.package == "minion-code@0.1.44")
    }

    @Test func picksPlatformBinary() throws {
        let opencode = try #require(decode().agent(id: "opencode"))
        guard case .binary(let arm, let cmd, let args, _, let sha) = opencode.distribution(for: .darwinArm64) else {
            Issue.record("expected binary")
            return
        }
        #expect(arm.absoluteString == "https://example.com/opencode-darwin-arm64.zip")
        #expect(cmd == "./opencode")
        #expect(args == ["acp"])
        #expect(sha == "95a1000000000000000000000000000000000000000000000000000000000000")
        guard case .binary(let intel, _, _, _, let intelSha) = opencode.distribution(for: .darwinX64) else {
            Issue.record("expected binary")
            return
        }
        #expect(intel.absoluteString == "https://example.com/opencode-darwin-x64.zip")
        #expect(intelSha == nil)
    }

    @Test func prefersBinaryOverNpxAndFallsBack() throws {
        let claude = try #require(decode().agent(id: "claude-acp"))
        if case .binary = claude.distribution(for: .darwinArm64) {} else { Issue.record("expected binary on arm64") }
        // No x86_64 binary in the sample, so the npx entry takes over.
        #expect(
            claude.distribution(for: .darwinX64)
                == .npx(package: "@agentclientprotocol/claude-agent-acp@0.110.0", args: [], env: [:])
        )
    }

    @Test func fallsBackToUvxAndNil() throws {
        let index = try decode()
        #expect(
            index.agent(id: "minion-code")?.distribution(for: .darwinArm64)
                == .uvx(package: "minion-code@0.1.44", args: ["acp"], env: [:])
        )
        #expect(index.agent(id: "nothing-fits")?.distribution(for: .darwinArm64) == nil)
    }

    @Test func directLaunchSpecs() throws {
        let index = try decode()
        let npx = try #require(index.agent(id: "auggie")?.distribution(for: .darwinArm64)?.directLaunchSpec)
        #expect(npx.command == .named("npx"))
        #expect(npx.arguments == ["-y", "@augmentcode/auggie@0.37.0", "--acp"])
        #expect(npx.environment["AUGMENT_DISABLE_AUTO_UPDATE"] == "1")
        let uvx = try #require(index.agent(id: "minion-code")?.distribution(for: .darwinArm64)?.directLaunchSpec)
        #expect(uvx.command == .named("uvx"))
        #expect(uvx.arguments == ["minion-code@0.1.44", "acp"])
        #expect(index.agent(id: "opencode")?.distribution(for: .darwinArm64)?.directLaunchSpec == nil)
    }

    @Test func currentPlatformIsDarwin() {
        #expect([ACPPlatform.darwinArm64, .darwinX64].contains(ACPPlatform.current))
    }

    @Test func missingAgentsKeyFailsTheIndex() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ACPRegistryIndex.self, from: Data(#"{"version":"1"}"#.utf8))
        }
    }

    @Test func bundledSnapshotHasTheThreeAgents() {
        let index = ACPBundledRegistry.index
        #expect(Set(index.agents.map(\.id)) == ["claude-acp", "codex-acp", "opencode"])
        #expect(index.agent(id: "opencode")?.distribution(for: .darwinArm64) != nil)
        #expect(
            index.agent(id: "codex-acp")?.distribution(for: .darwinX64)
                == .npx(package: "@agentclientprotocol/codex-acp@2.10.0", args: [], env: [:])
        )
    }
}
