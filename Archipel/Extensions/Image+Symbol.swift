import AppKit
import os
import SwiftUI

/// Which symbol names the asset catalog has. Every sidebar row and tab asks from its body, and most
/// names are SF Symbols, where the lookup builds an image only to find nothing. The catalog cannot
/// change while the app runs, so each name is looked up once.
private enum CatalogSymbols {
    private static let known = OSAllocatedUnfairLock(initialState: [String: Bool]())

    static func contains(_ name: String) -> Bool {
        known.withLock { known in
            if let answer = known[name] { return answer }
            let answer = NSImage(symbolName: name, bundle: .main, variableValue: 0) != nil
            known[name] = answer
            return answer
        }
    }
}

extension Image {
    /// Agent logos are custom symbols in the asset catalog, since SF Symbols has no brand marks.
    /// `Image(systemName:)` can't load those, so anything showing an agent's symbol goes through here.
    ///
    /// Logos use multicolor so the colour baked into them (Claude's orange) wins over the `.secondary`
    /// and `.tint` styles around them. System symbols stay as they are, as some have multicolor
    /// variants we don't want.
    init(symbol name: String) {
        if CatalogSymbols.contains(name) {
            self = Image(name).symbolRenderingMode(.multicolor)
        } else {
            self.init(systemName: name)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, symbol name: String) {
        self.init { Text(title) } icon: { Image(symbol: name) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, symbol name: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, symbol: name) }
    }
}
