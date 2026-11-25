import Foundation

public struct ACPRegistryIndex: Codable, Sendable, Equatable {
    public var version: String?
    public var agents: [ACPRegistryAgent]

    public init(version: String? = nil, agents: [ACPRegistryAgent]) {
        self.version = version
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey {
        case version, agents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? nil
        agents = try container.decode([Lossy<ACPRegistryAgent>].self, forKey: .agents).compactMap(\.value)
    }

    public func agent(id: String) -> ACPRegistryAgent? {
        agents.first { $0.id == id }
    }
}

/// One agent entry. Only the fields Archipel needs are modelled; unknown keys are ignored.
public struct ACPRegistryAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var repository: String?
    public var website: String?
    public var authors: [String]
    public var license: String?
    public var icon: String?
    public var distribution: ACPRegistryDistribution

    public init(
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        repository: String? = nil,
        website: String? = nil,
        authors: [String] = [],
        license: String? = nil,
        icon: String? = nil,
        distribution: ACPRegistryDistribution
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.repository = repository
        self.website = website
        self.authors = authors
        self.license = license
        self.icon = icon
        self.distribution = distribution
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, repository, website, authors, license, icon, distribution
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        distribution = try container.decode(ACPRegistryDistribution.self, forKey: .distribution)
        // Cosmetic fields: a wrong type there must not cost us an installable agent.
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        repository = (try? container.decodeIfPresent(String.self, forKey: .repository)) ?? nil
        website = (try? container.decodeIfPresent(String.self, forKey: .website)) ?? nil
        authors = (try? container.decodeIfPresent([String].self, forKey: .authors)) ?? []
        license = (try? container.decodeIfPresent(String.self, forKey: .license)) ?? nil
        icon = (try? container.decodeIfPresent(String.self, forKey: .icon)) ?? nil
    }
}

/// The ways the registry says an agent can be obtained.
public struct ACPRegistryDistribution: Codable, Sendable, Equatable {
    /// Keyed by platform string such as `darwin-aarch64`.
    public var binary: [String: ACPRegistryBinary]
    public var npx: ACPRegistryPackage?
    public var uvx: ACPRegistryPackage?

    public init(
        binary: [String: ACPRegistryBinary] = [:],
        npx: ACPRegistryPackage? = nil,
        uvx: ACPRegistryPackage? = nil
    ) {
        self.binary = binary
        self.npx = npx
        self.uvx = uvx
    }

    private enum CodingKeys: String, CodingKey {
        case binary, npx, uvx
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Platforms we never run on (windows, linux) may be malformed without mattering, so each
        // platform entry is decoded on its own.
        let platforms = (try? container.decodeIfPresent([String: Lossy<ACPRegistryBinary>].self, forKey: .binary)) ?? nil
        binary = (platforms ?? [:]).compactMapValues(\.value)
        npx = (try? container.decodeIfPresent(ACPRegistryPackage.self, forKey: .npx)) ?? nil
        uvx = (try? container.decodeIfPresent(ACPRegistryPackage.self, forKey: .uvx)) ?? nil
    }
}

/// A downloadable archive (or raw binary) for one platform.
public struct ACPRegistryBinary: Codable, Sendable, Equatable {
    public var archive: String
    /// Relative to the unpacked archive root, for example `./claude-agent-acp`.
    public var cmd: String
    public var args: [String]
    public var env: [String: String]
    public var sha256: String?

    public init(
        archive: String,
        cmd: String,
        args: [String] = [],
        env: [String: String] = [:],
        sha256: String? = nil
    ) {
        self.archive = archive
        self.cmd = cmd
        self.args = args
        self.env = env
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case archive, cmd, args, env, sha256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archive = try container.decode(String.self, forKey: .archive)
        cmd = try container.decode(String.self, forKey: .cmd)
        args = (try? container.decodeIfPresent([String].self, forKey: .args)) ?? []
        env = (try? container.decodeIfPresent([String: String].self, forKey: .env)) ?? [:]
        // Strict, unlike the cosmetic fields: a checksum that cannot be read must not turn into
        // no checksum, which would install the download unverified. The platform is dropped.
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        if let sha256, !Self.isSHA256(sha256) {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: container, debugDescription: "Not a SHA-256 hex digest")
        }
    }

    /// 64 hex digits, in either case, with surrounding whitespace allowed as the installer allows it.
    static func isSHA256(_ value: String) -> Bool {
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return digits.utf8.count == 64 && digits.allSatisfy(\.isHexDigit)
    }
}

/// An `npx` or `uvx` package spec.
public struct ACPRegistryPackage: Codable, Sendable, Equatable {
    public var package: String
    public var args: [String]
    public var env: [String: String]

    public init(package: String, args: [String] = [], env: [String: String] = [:]) {
        self.package = package
        self.args = args
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case package, args, env
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        package = try container.decode(String.self, forKey: .package)
        args = (try? container.decodeIfPresent([String].self, forKey: .args)) ?? []
        env = (try? container.decodeIfPresent([String: String].self, forKey: .env)) ?? [:]
    }
}

public struct ACPPlatform: Sendable, Equatable, Hashable {
    public var identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public static let darwinArm64 = ACPPlatform("darwin-aarch64")
    public static let darwinX64 = ACPPlatform("darwin-x86_64")

    /// Asks the kernel at run time rather than trusting the compile-time architecture.
    public static var current: ACPPlatform {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine == "arm64" ? .darwinArm64 : .darwinX64
    }
}

/// How an agent entry resolves for one machine.
public enum ACPDistribution: Sendable, Equatable {
    case binary(archive: URL, cmd: String, args: [String], env: [String: String], sha256: String?)
    case npx(package: String, args: [String], env: [String: String])
    case uvx(package: String, args: [String], env: [String: String])

    /// The launch recipe for distributions that need no install step. Nil for `.binary`, which
    /// must go through `ACPInstaller` first.
    public var directLaunchSpec: ACPLaunchSpec? {
        switch self {
        case .binary:
            nil
        case .npx(let package, let args, let env):
            ACPLaunchSpec(command: .named("npx"), arguments: ["-y", package] + args, environment: env)
        case .uvx(let package, let args, let env):
            ACPLaunchSpec(command: .named("uvx"), arguments: [package] + args, environment: env)
        }
    }
}

extension ACPRegistryAgent {
    /// Picks the best distribution for `platform`: a matching binary, then npx, then uvx.
    public func distribution(for platform: ACPPlatform = .current) -> ACPDistribution? {
        if let binary = distribution.binary[platform.identifier], let archive = URL(string: binary.archive) {
            return .binary(
                archive: archive,
                cmd: binary.cmd,
                args: binary.args,
                env: binary.env,
                sha256: binary.sha256
            )
        }
        if let npx = distribution.npx {
            return .npx(package: npx.package, args: npx.args, env: npx.env)
        }
        if let uvx = distribution.uvx {
            return .uvx(package: uvx.package, args: uvx.args, env: uvx.env)
        }
        return nil
    }
}

/// A resolved way to start an agent process. Named apart from AgentKit's `LaunchCommand`.
public struct ACPLaunchSpec: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        /// An absolute file, such as an installed binary.
        case file(URL)
        /// A bare command name the caller must look up on the PATH (`npx`, `uvx`).
        case named(String)
    }

    public var command: Command
    public var arguments: [String]
    public var environment: [String: String]

    public init(command: Command, arguments: [String] = [], environment: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}
