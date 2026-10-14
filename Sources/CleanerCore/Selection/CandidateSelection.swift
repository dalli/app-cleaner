import Foundation

extension Array where Element == Candidate {
    /// 실제로 옮길 항목 (정리 계획용).
    /// 부모(컨테이너)가 선택되어 있으면 부모 하나만, 아니면 선택된 하위 항목을 펼쳐 돌려준다.
    /// 선택 불가(보호·동기화) 항목은 제외한다. `selectedItems`와 달리 부모·자식이 함께 들어가지 않는다.
    public var itemsToMove: [Candidate] {
        flatMap { c -> [Candidate] in
            if c.isSelected && c.isSelectable { return [c] }
            return c.children.itemsToMove
        }
    }
}
