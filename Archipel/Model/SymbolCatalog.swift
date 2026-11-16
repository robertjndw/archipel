import Foundation

/// Every SF Symbol this Mac can draw, with the categories and search keywords the SF Symbols app
/// uses. There is no public API for the list, so it is read from the metadata macOS ships next to
/// the glyphs. That keeps it in step with the OS: a symbol listed here is one the system can render.
/// Should the files ever move, the catalog comes back empty and pickers fall back to their suggestions.
nonisolated struct SymbolCatalog: Sendable {
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let icon: String
    }

    static let shared = SymbolCatalog.load()

    /// The browsing order for "All": category by category, the way the SF Symbols app groups them.
    let symbols: [String]
    let categories: [Category]
    private let members: [String: [String]]
    private let keywords: [String: [String]]
    /// `.fill` spellings of symbols that also exist as an outline.
    private let fillVariants: Set<String>

    static let all = Category(id: "all", title: "All", icon: "square.grid.2x2")

    /// Matches the name and the keywords, so "home" finds `house` as it does in the SF Symbols app.
    /// Leave out the fill variants where the symbol gets filled anyway, as islands do when selected:
    /// there they would pick the same icon twice.
    func search(_ query: String, in category: Category.ID, includingFills: Bool) -> [String] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let pool = category == Self.all.id ? symbols : members[category] ?? []
        return pool.filter { name in
            if !includingFills, fillVariants.contains(name) { return false }
            return terms.allSatisfy { term in
                name.contains(term) || keywords[name, default: []].contains { $0.hasPrefix(term) }
            }
        }
    }

    // MARK: Loading

    private static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Script and right-to-left variants of the same glyph, which would otherwise show up as
    /// near-duplicates next to every symbol with a localized form.
    private static let localeSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mni", "mr", "my",
        "or", "pa", "rtl", "ru", "sat", "si", "ta", "te", "th", "zh",
    ]

    /// Feature showcases rather than subjects. Every symbol in them also sits in a real category.
    private static let skippedCategories: Set<String> = ["all", "whatsnew", "draw", "variable", "multicolor"]

    private static let titles: [String: String] = [
        "objectsandtools": "Objects & Tools",
        "cameraandphotos": "Camera & Photos",
        "privacyandsecurity": "Privacy & Security",
        "textformatting": "Text Formatting",
    ]

    private static func load() -> SymbolCatalog {
        guard
            let names = plist([String].self, "symbol_order.plist"),
            let categoryList = plist([[String: String]].self, "categories.plist"),
            let membership = plist([String: [String]].self, "symbol_categories.plist")
        else { return fallback }
        // Apple allows these only for referring to its own features, like the Accessibility settings.
        let restricted = Set((NSDictionary(contentsOf: resources.appending(path: "symbol_restrictions.strings")) as? [String: String] ?? [:]).keys)
        let search = plist([String: [String]].self, "symbol_search.plist") ?? [:]

        let usable = names.filter { name in
            if restricted.contains(name) { return false }
            let parts = name.split(separator: ".")
            if let last = parts.last, parts.count > 1, localeSuffixes.contains(String(last)) { return false }
            return true
        }
        let available = Set(usable)
        let fillVariants = Set(usable.filter { name in
            let parts = name.split(separator: ".")
            guard parts.contains("fill") else { return false }
            return available.contains(parts.filter { $0 != "fill" }.joined(separator: "."))
        })

        var members: [String: [String]] = [:]
        for name in usable {
            for category in membership[name] ?? [] where !skippedCategories.contains(category) {
                members[category, default: []].append(name)
            }
        }
        let categories = categoryList.compactMap { entry -> Category? in
            guard let key = entry["key"], let icon = entry["icon"], !skippedCategories.contains(key),
                  members[key]?.isEmpty == false else { return nil }
            return Category(id: key, title: titles[key] ?? key.capitalized, icon: icon)
        }

        var seen = Set<String>()
        var ordered: [String] = []
        for category in categories {
            for name in members[category.id] ?? [] where seen.insert(name).inserted { ordered.append(name) }
        }
        ordered += usable.filter { !seen.contains($0) }

        guard !ordered.isEmpty else { return fallback }
        return SymbolCatalog(
            symbols: ordered, categories: categories, members: members, keywords: search, fillVariants: fillVariants
        )
    }

    private static func plist<T>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: resources.appending(path: name)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? T
    }

    private static let fallback = SymbolCatalog(symbols: [], categories: [], members: [:], keywords: [:], fillVariants: [])
}
