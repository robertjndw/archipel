/// Random two-word branch names like `quiet-harbor`, for worktrees the user has not named yet.
public enum PlaceholderName {
    // Neutral words only: no git vocabulary (main, head, branch, ...) that could be mistaken for
    // a real ref, and no "island", which already means something in the app.
    public static let adjectives: [String] = [
        "amber", "ancient", "azure", "bright", "brisk", "calm", "clear", "cloudy",
        "cobalt", "coral", "crisp", "dawn", "deep", "dusky", "eager", "faint",
        "fair", "foggy", "gentle", "golden", "grassy", "hazy", "humble", "icy",
        "jade", "keen", "lively", "lucky", "mellow", "merry", "misty", "mossy",
        "narrow", "nimble", "open", "pale", "patient", "plain", "polar", "proud",
        "quiet", "rainy", "rocky", "rosy", "rustic", "sandy", "silver", "slow",
        "snowy", "soft", "steady", "still", "sunny", "swift", "tidal", "tiny",
        "vast", "velvet", "warm", "wild", "windy", "winter", "woolly", "young",
    ]

    public static let nouns: [String] = [
        "anchor", "bay", "beacon", "birch", "breeze", "brook", "canyon", "cape",
        "cedar", "cliff", "cove", "creek", "current", "dune", "ember", "falcon",
        "fern", "fjord", "forest", "gull", "harbor", "heron", "hill", "lagoon",
        "lake", "lantern", "meadow", "moss", "oak", "ocean", "otter", "pebble",
        "pine", "pond", "puffin", "reef", "ridge", "river", "robin", "sail",
        "sand", "seal", "shore", "sparrow", "spruce", "star", "stone", "storm",
        "strait", "stream", "summit", "swan", "thistle", "tide", "trail", "valley",
        "wave", "willow", "wind", "wren", "marsh", "orchard", "pier", "grove",
    ]

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        // The lists are non-empty constants, so randomElement cannot return nil.
        "\(adjectives.randomElement(using: &generator)!)-\(nouns.randomElement(using: &generator)!)"
    }

    /// Falls back to a numeric suffix because with a small word pool a repository that has used
    /// many placeholders can make every random attempt collide.
    public static func unused<G: RandomNumberGenerator>(using generator: inout G, attempts: Int = 20, isTaken: (String) -> Bool) -> String {
        var candidate = random(using: &generator)
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { candidate = random(using: &generator) }
            if !isTaken(candidate) { return candidate }
        }
        var suffix = 2
        while isTaken("\(candidate)-\(suffix)") { suffix += 1 }
        return "\(candidate)-\(suffix)"
    }
}
