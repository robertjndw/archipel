import Foundation

/// Offline fallback holding only the agents Archipel ships support for. It goes through the same
/// decoder as the live index, so the two cannot drift in shape. Refresh it from the real registry
/// when the pinned versions move; the darwin platforms are enough because nothing else can run here.
public enum ACPBundledRegistry {
    public static var index: ACPRegistryIndex {
        let decoded = try? JSONDecoder().decode(ACPRegistryIndex.self, from: Data(json.utf8))
        return decoded ?? ACPRegistryIndex(agents: [])
    }

    static let json = #"""
    {
      "version": "1.0.0",
      "agents": [
        {
          "id": "claude-acp",
          "name": "Claude Agent",
          "version": "0.110.0",
          "description": "ACP wrapper for Anthropic's Claude",
          "repository": "https://github.com/agentclientprotocol/claude-agent-acp",
          "authors": ["Anthropic", "Zed Industries", "JetBrains"],
          "license": "proprietary",
          "distribution": {
            "binary": {
              "darwin-aarch64": {
                "archive": "https://github.com/agentclientprotocol/claude-agent-acp/releases/download/v0.110.0/claude-agent-acp-darwin-arm64.zip",
                "cmd": "./claude-agent-acp",
                "sha256": "9b6e176ea52947442b0f995c7cd8a1718fd806fc8563bf92d81fb9dfd7010877"
              },
              "darwin-x86_64": {
                "archive": "https://github.com/agentclientprotocol/claude-agent-acp/releases/download/v0.110.0/claude-agent-acp-darwin-x64.zip",
                "cmd": "./claude-agent-acp",
                "sha256": "bde50c8616718a0a2657486fc2c635e21d58744a6bfbb847ff374145f4649c67"
              }
            },
            "npx": { "package": "@agentclientprotocol/claude-agent-acp@0.110.0" }
          }
        },
        {
          "id": "codex-acp",
          "name": "Codex",
          "version": "2.10.0",
          "description": "ACP adapter for OpenAI's coding assistant",
          "repository": "https://github.com/agentclientprotocol/codex-acp",
          "authors": ["OpenAI", "JetBrains s.r.o", "Zed Industries"],
          "license": "Apache-2.0",
          "distribution": {
            "npx": { "package": "@agentclientprotocol/codex-acp@2.10.0" }
          }
        },
        {
          "id": "opencode",
          "name": "OpenCode",
          "version": "2.4.1",
          "description": "The open source coding agent",
          "repository": "https://github.com/anomalyco/opencode",
          "website": "https://opencode.ai",
          "authors": ["Anomaly"],
          "license": "MIT",
          "distribution": {
            "binary": {
              "darwin-aarch64": {
                "archive": "https://github.com/anomalyco/opencode/releases/download/v2.4.1/opencode-darwin-arm64.zip",
                "cmd": "./opencode",
                "args": ["acp"],
                "sha256": "95a101eda95108478f1db43cff8fcbd4811f6c0e79af1e167301843c6a48d731"
              },
              "darwin-x86_64": {
                "archive": "https://github.com/anomalyco/opencode/releases/download/v2.4.1/opencode-darwin-x64.zip",
                "cmd": "./opencode",
                "args": ["acp"],
                "sha256": "a7a4c758a32488138531ab2d82be86e2a1438c35c017664f83daa1d5b63bb82c"
              }
            }
          }
        }
      ]
    }
    """#
}
