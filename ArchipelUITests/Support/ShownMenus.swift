import XCTest

/// Looking into a context menu without picking anything from it, and finding text by part of what
/// it says.
extension ArchipelUITestCase {
    /// The item of the context menu that a right click just opened, once the menu is up. The menu
    /// bar has items of the same names, so only one that is on screen counts.
    func shownMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let candidates = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        var shown: XCUIElement?
        waitUntil("the menu shows \(title)", file: file, line: line) {
            shown = candidates.allElementsBoundByIndex.first(where: \.isHittable)
            return shown != nil
        }
        return shown
    }

    /// Whether the open menu has an item of this title. Asked once, without waiting, so call it
    /// after `shownMenuItem` has seen the menu up.
    func menuShows(_ title: String) -> Bool {
        app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.contains(where: \.isHittable)
    }

    /// Text anywhere in the app, alerts and sheets included, that contains `fragment`. SwiftUI
    /// reports a Text as its label in some places and as its value in others.
    func staticText(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).element(boundBy: 0)
    }

    /// The button of an alert or dialog, found by its title wherever the dialog is attached.
    func dialogButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).element(boundBy: 0)
    }
}
