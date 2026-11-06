// Lista las ventanas visibles de ClaudeSniper: "id capa x y ancho alto"
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "ClaudeSniper" {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
