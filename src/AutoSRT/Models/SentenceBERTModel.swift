import Foundation
import CoreML

/// Input type for SentenceBERT CoreML model
class SentenceBERTInput: MLFeatureProvider {
    /// Input token IDs
    var input_ids: MLMultiArray
    /// Attention mask
    var attention_mask: MLMultiArray
    
    var featureNames: Set<String> {
        return ["input_ids", "attention_mask"]
    }
    
    init(input_ids: MLMultiArray, attention_mask: MLMultiArray) {
        self.input_ids = input_ids
        self.attention_mask = attention_mask
    }
    
    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "input_ids":
            return MLFeatureValue(multiArray: input_ids)
        case "attention_mask":
            return MLFeatureValue(multiArray: attention_mask)
        default:
            return nil
        }
    }
}

/// Output type for SentenceBERT CoreML model
class SentenceBERTOutput: MLFeatureProvider {
    /// Model output embedding
    var embedding: MLMultiArray
    
    var featureNames: Set<String> {
        return ["embedding"]
    }
    
    init(features: MLFeatureProvider) throws {
        guard let embeddingValue = features.featureValue(for: "embedding"),
              let embedding = embeddingValue.multiArrayValue else {
            throw NSError(domain: "SentenceBERTOutput", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid embedding feature"])
        }
        self.embedding = embedding
    }
    
    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "embedding" {
            return MLFeatureValue(multiArray: embedding)
        }
        return nil
    }
}
