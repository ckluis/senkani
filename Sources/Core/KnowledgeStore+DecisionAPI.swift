import Foundation

// Public forwarders for the decision-record surface, delegating to `DecisionStore`.
extension KnowledgeStore {

    @discardableResult
    public func insertDecision(_ record: DecisionRecord) -> Int64 {
        decisionStore.insertDecision(record)
    }

    public func decisions(forEntityName name: String) -> [DecisionRecord] {
        decisionStore.decisions(forEntityName: name)
    }
}
