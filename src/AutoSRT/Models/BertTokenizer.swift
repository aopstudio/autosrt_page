import Foundation

struct Token {
    let id: Int
    let piece: String
}

class BertTokenizer {
    private let vocabulary: [String: Int]
    private let unkToken = "[UNK]"
    private let clsToken = "[CLS]"
    private let sepToken = "[SEP]"
    private let padToken = "[PAD]"

    init(_ vocabName: String = "vocab") {
        // Load vocabulary from JSON file
        if let url = Bundle.main.url(forResource: vocabName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let vocab = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        {
            vocabulary = vocab
            LoggerService.shared.log(
                "Successfully loaded vocabulary with \(vocab.count) tokens from \(vocabName)")
        } else {
            vocabulary = [:]
            LoggerService.shared.log("Failed to load vocabulary from \(vocabName)", level: .error)
        }
    }

    public func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []

        // Add [CLS] token at start
        if let clsId = vocabulary[clsToken] {
            tokens.append(Token(id: clsId, piece: clsToken))
        }

        // Tokenize text
        let normalizedText = text.lowercased()
        var currentPiece = ""

        for char in normalizedText {
            if char.isWhitespace || char.isPunctuation {
                if !currentPiece.isEmpty {
                    let pieceTokens = tokenizeWord(currentPiece)
                    tokens.append(contentsOf: pieceTokens)
                    currentPiece = ""
                }
                // Add the whitespace/punctuation as a separate token
                let charString = String(char)
                if let id = vocabulary[charString] {
                    tokens.append(Token(id: id, piece: charString))
                }
            } else {
                currentPiece.append(char)
            }
        }

        // Handle any remaining piece
        if !currentPiece.isEmpty {
            let pieceTokens = tokenizeWord(currentPiece)
            tokens.append(contentsOf: pieceTokens)
        }

        // Add [SEP] token at end
        if let sepId = vocabulary[sepToken] {
            tokens.append(Token(id: sepId, piece: sepToken))
        }

        return tokens
    }

    /// Tokenize a query-passage pair for cross-encoder input
    func tokenizePair(query: String, passage: String) -> (inputIds: [Int], attentionMask: [Int]) {
        
        // Special tokens
        let clsToken = vocabulary[clsToken] ?? 101
        let sepToken = vocabulary[sepToken] ?? 102
        let padToken = vocabulary[padToken] ?? 0
        
        // Tokenize query and passage
        let queryTokens = tokenize(query)
        let passageTokens = tokenize(passage)
        
        // Construct input IDs: [CLS] query [SEP] passage [SEP]
        var inputIds = [clsToken]
        inputIds.append(contentsOf: queryTokens.map { $0.id })
        inputIds.append(sepToken)
        inputIds.append(contentsOf: passageTokens.map { $0.id })
        inputIds.append(sepToken)
        
        // Create attention mask (1 for real tokens, 0 for padding)
        let attentionMask = Array(repeating: 1, count: inputIds.count)
        
        // Truncate or pad to maxLength
        let maxLength = Settings.LLMService.maxTokenLength
        if inputIds.count > maxLength {
            // Truncate
            inputIds = Array(inputIds.prefix(maxLength))
            return (inputIds, Array(repeating: 1, count: maxLength))
        } else {
            // Pad
            let paddingLength = maxLength - inputIds.count
            let paddedInputIds = inputIds + Array(repeating: padToken, count: paddingLength)
            let paddedAttentionMask = attentionMask + Array(repeating: 0, count: paddingLength)
            return (paddedInputIds, paddedAttentionMask)
        }
    }

    public func tokenizeAndPad(_ text: String) -> ([Int], [Int]) {
        let tokens = tokenize(text)
        var inputIds: [Int] = []
        var attentionMask: [Int] = []

        // Add token IDs and attention mask
        for token in tokens {
            inputIds.append(token.id)
            attentionMask.append(1)
        }

        // Pad to maxLength
        let padId = vocabulary[padToken] ?? 0
        while inputIds.count < Settings.LLMService.maxTokenLength {
            inputIds.append(padId)
            attentionMask.append(0)
        }

        // Truncate if necessary
        if inputIds.count > Settings.LLMService.maxTokenLength {
            inputIds = Array(inputIds[..<Settings.LLMService.maxTokenLength])
            attentionMask = Array(attentionMask[..<Settings.LLMService.maxTokenLength])
        }

        return (inputIds, attentionMask)
    }

    private func tokenizeWord(_ word: String) -> [Token] {
        if let id = vocabulary[word] {
            return [Token(id: id, piece: word)]
        }

        // If word is not in vocabulary, try to split it into subwords
        var tokens: [Token] = []
        var start = 0

        while start < word.count {
            var end = word.count
            var found = false

            while end > start && !found {
                let substring = String(
                    word[
                        word.index(
                            word.startIndex, offsetBy: start)..<word.index(
                                word.startIndex, offsetBy: end)])
                if let id = vocabulary[substring] {
                    tokens.append(Token(id: id, piece: substring))
                    start = end
                    found = true
                }
                end -= 1
            }

            if !found {
                // If no subword is found, add unknown token and advance by one character
                if let unkId = vocabulary[unkToken] {
                    tokens.append(Token(id: unkId, piece: unkToken))
                }
                start += 1
            }
        }

        return tokens
    }
}
