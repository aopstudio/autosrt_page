import Foundation

extension Sequence {
    func chunked(into size: Int) -> [[Element]] {
        var result: [[Element]] = []
        var currentChunk: [Element] = []
        
        for element in self {
            currentChunk.append(element)
            if currentChunk.count == size {
                result.append(currentChunk)
                currentChunk = []
            }
        }
        
        if !currentChunk.isEmpty {
            result.append(currentChunk)
        }
        
        return result
    }
}
