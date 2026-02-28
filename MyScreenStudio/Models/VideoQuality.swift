import Foundation

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "4K"

    var id: String { rawValue }
}
