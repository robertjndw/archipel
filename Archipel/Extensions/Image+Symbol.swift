import AppKit
import SwiftUI

extension Image {
    /// Agent logos are custom symbols in the asset catalog, since SF Symbols has no brand marks.
    /// `Image(systemName:)` can't load those, so anything showing an agent's symbol goes through here.
    ///
    /// Logos use multicolor so the colour baked into them (Claude's orange) wins over the `.secondary`
    /// and `.tint` styles around them. System symbols stay as they are, as some have multicolor
    /// variants we don't want.
    init(symbol name: String) {
        if NSImage(symbolName: name, bundle: .main, variableValue: 0) != nil {
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
