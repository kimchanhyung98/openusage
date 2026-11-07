import Foundation

/// dashboard에 배치된 widget 하나.
/// 안정적 `id`가 reorder/animation identity, `descriptorID`가 registry의 data·render kind 연결.
struct PlacedWidget: Identifiable, Hashable, Codable {
    var id: UUID
    let descriptorID: String

    init(id: UUID = UUID(), descriptorID: String) {
        self.id = id
        self.descriptorID = descriptorID
    }
}
