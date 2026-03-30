import Foundation
import AppKit

extension String {
    func size(fontSize: CGFloat, fontName: String = "Songti SC") -> CGSize {
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let attributes = [NSAttributedString.Key.font: font]
        let size = (self as NSString).size(withAttributes: attributes)
        return size
    }
    
    func width(fontSize: CGFloat, fontName: String = "Songti SC") -> CGFloat {
        return size(fontSize: fontSize, fontName: fontName).width
    }
    
    func height(fontSize: CGFloat, fontName: String = "Songti SC") -> CGFloat {
        return size(fontSize: fontSize, fontName: fontName).height
    }
    
    var hasChineseCharacters: Bool {
        return self.range(of: "[\\u4e00-\\u9faf]", options: .regularExpression) != nil
    }
}
