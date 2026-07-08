import SwiftUI

enum MotionTokens {
    static let micro = Animation.easeInOut(duration: 0.18)
    static let page = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let reveal = Animation.easeOut(duration: 0.42)
}
