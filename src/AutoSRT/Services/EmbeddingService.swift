import CoreML
import Foundation


final class EmbeddingService: @unchecked Sendable {
    static let shared = EmbeddingService()
    private let logger = LoggerService.shared
    private var model: MLModel?
    private let tokenizer: BertTokenizer
    private let embeddingCache = NSCache<NSString, NSArray>()
    private let downloadService = DownloadService.shared
    private var isInitialized = false

    private init() {
        // Initialize tokenizer
        tokenizer = BertTokenizer("vocab")
        loadModel()
        // Configure cache limits
        embeddingCache.countLimit = 1000  // Store up to 10000 embeddings
    }

    func loadModel() {
        if model != nil {
            return
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        // Load model
        do {
            guard
                let modelURL = Bundle.main.url(
                    forResource: "SentenceBERT", withExtension: "mlmodelc")
            else {
                logger.log("SentenceBERT.mlmodelc not found in bundle", level: .error)
                return
            }
            model = try MLModel(contentsOf: modelURL, configuration: config)
            logger.log("Successfully loaded SentenceBERT model")
            isInitialized = true

            // Log model description
            if let description = model?.modelDescription {
                logger.log("Model inputs: \(description.inputDescriptionsByName)")
                logger.log("Model outputs: \(description.outputDescriptionsByName)")
            }
        } catch {
            logger.log(
                "Failed to load SentenceBERT model: \(error.localizedDescription)", level: .error)
            AnalyticsService.shared.trackError(error, context: "embedding_service")
        }
    }
    
    /// Initialize the model, downloading it if it doesn't exist
    func initializeModel(progressHandler: ((@Sendable (DownloadService.DownloadProgress) -> Void))? = nil) async throws {
        // If model is already initialized, return
        if isInitialized && model != nil {
            return
        }
        
        // Check if model exists in bundle
        if let _ = Bundle.main.url(forResource: "SentenceBERT", withExtension: "mlmodelc") {
            loadModel()
            return
        }
        
        // Model doesn't exist, download it
        logger.log("SentenceBERT model not found in bundle, downloading...", level: .info)
        
        // Get application support directory
        let appSupportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        // Create models directory
        let modelsDir = appSupportDir.appendingPathComponent("AutoSRT/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true, attributes: nil)
        
        // Check if model already exists in application support directory
        let modelDir = modelsDir.appendingPathComponent("SentenceBERT/SentenceBERT.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            // Load model from application support directory
            let config = MLModelConfiguration()
            config.computeUnits = .all
            
            do {
                model = try MLModel(contentsOf: modelDir, configuration: config)
                logger.log("Successfully loaded SentenceBERT model from application support directory")
                isInitialized = true
                return
            } catch {
                logger.log("Failed to load SentenceBERT model from application support directory: \(error.localizedDescription)", level: .error)
                // Continue to download the model
            }
        }
        
        // Download the model
        guard let modelURL = URL(string: Settings.LLMService.sentenceModelUrl) else {
            throw EmbeddingError.modelNotFound
        }
        
        // Download the model
        let downloadedURL = try await downloadService.downloadModel(
            from: modelURL,
            modelName: "SentenceBERT",
            destinationDirectory: modelsDir
        ) { @Sendable progress in
            // self.logger.log("Downloading SentenceBERT model: \(Int(progress.progress * 100))%", level: .info)
            progressHandler?(progress)
        }
        
        // Load the downloaded model
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        do {
            let modelPath = downloadedURL.appendingPathComponent("SentenceBERT.mlmodelc", isDirectory: true)
            model = try MLModel(contentsOf: modelPath, configuration: config)
            logger.log("Successfully loaded downloaded SentenceBERT model")
            isInitialized = true
        } catch {
            logger.log("Failed to load downloaded SentenceBERT model: \(error.localizedDescription)", level: .error)
            throw EmbeddingError.modelLoadFailed
        }
    }

    func getEmbedding(for text: String) throws -> [Float] {
        // Check if model is initialized
        if model == nil {
            loadModel()
        }
        
        // Check cache first
        let cacheKey = text as NSString
        if let cachedEmbedding = embeddingCache.object(forKey: cacheKey) as? [NSNumber] {
            //logger.log("Cache hit for text: '\(text)'")
            return cachedEmbedding.map { Float(truncating: $0) }
        }

        guard let model = model else {
            logger.log("Model not loaded", level: .error)
            throw EmbeddingError.modelNotLoaded
        }

        // Validate input
        guard !text.isEmpty else {
            logger.log("Empty input text", level: .error)
            throw EmbeddingError.invalidInput
        }

        // Tokenize input text
        var (inputIds, attentionMask) = tokenizer.tokenizeAndPad(text)

        // Create MLMultiArray inputs
        let inputIdsArray: MLMultiArray
        let attentionMaskArray: MLMultiArray
        do {
            inputIdsArray = try MLMultiArray(
                shape: [1, NSNumber(value: Settings.LLMService.maxTokenLength)], dataType: .int32)
            attentionMaskArray = try MLMultiArray(
                shape: [1, NSNumber(value: Settings.LLMService.maxTokenLength)], dataType: .int32)
        } catch {
            logger.log(
                "Failed to create input arrays: \(error.localizedDescription)", level: .error)
            throw EmbeddingError.invalidInput
        }

        for i in 0..<Settings.LLMService.maxTokenLength {
            inputIdsArray[i] = NSNumber(value: inputIds[i])
            attentionMaskArray[i] = NSNumber(value: attentionMask[i])
        }

        // Create model input
        let input = SentenceBERTInput(input_ids: inputIdsArray, attention_mask: attentionMaskArray)

        // Get prediction
        do {
            let prediction = try model.prediction(from: input)
            //logger.log("Raw prediction type: \(type(of: prediction))")
            //logger.log("Available features: \(prediction.featureNames)")

            // Create output from prediction features
            let output = try SentenceBERTOutput(features: prediction)

            // Convert output to [Float]
            let embedding = (0..<output.embedding.count).map {
                Float(truncating: output.embedding[$0])
            }

            // Cache the result
            let cachedArray = embedding.map { NSNumber(value: $0) } as NSArray
            embeddingCache.setObject(cachedArray, forKey: cacheKey)

            //logger.log("Successfully generated and cached embedding of size \(embedding.count)")
            return embedding

        } catch {
            logger.log("Prediction failed: \(error.localizedDescription)", level: .error)
            throw EmbeddingError.predictionFailed
        }
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            logger.log("Vector size mismatch: \(a.count) vs \(b.count)", level: .error)
            return 0.0
        }

        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        normA = sqrt(normA)
        normB = sqrt(normB)

        guard normA > 0 && normB > 0 else {
            logger.log("Zero norm detected", level: .error)
            return 0.0
        }
        return dotProduct / (normA * normB)
    }
    
    /// MARK: compute similarity
    func computeSimilarity(_ text1: String, _ text2: [String]) -> Double {
        var totalSimilarity = 0.0
        var count = 0
        
        do {
            let text1Embedding = try getEmbedding(for: text1)
            
            for text in text2 {
                if !text.isEmpty {
                    let text2Embedding = try getEmbedding(for: text)
                    let similarity = try cosineSimilarity(text1Embedding, text2Embedding)
                    totalSimilarity += Double(similarity)
                    count += 1
                }
            }
        } catch {
            logger.log("Failed to compute similarity: \(error.localizedDescription)", level: .error)
            return 0.0
        }
        
        return count > 0 ? totalSimilarity / Double(count) : 0.0
    }
    
    /// Compute embeddings for multiple texts in parallel with limited concurrency
    func computeDocumentSimilarity(_ query: String, _ doc: [String], maxChunks: Int = 10, progressCallback: ((Double, String) -> Void)? = nil) -> Double {
        let concurrentQueue = DispatchQueue(label: "com.llmsurf.embedding", attributes: .concurrent)
        let resultsQueue = DispatchQueue(label: "com.llmsurf.embedding.results") // Serial queue for thread safety
        let semaphore = DispatchSemaphore(value: 3) // Limit concurrency to 3 tasks
        let group = DispatchGroup()
        
        var topChunkScores: [Double] = []
        
        do {
            let queryEmbedding = try getEmbedding(for: query)
            progressCallback?(0.1, "Computed query embedding")
            
            // Process embeddings in parallel with limited concurrency
            for (index, text) in doc.enumerated() {
                // Wait for a slot to become available
                semaphore.wait()
                
                concurrentQueue.async(group: group) {
                    // Use a separate Task for the MainActor work
                    Task { @MainActor in
                        defer {
                            // Signal that a slot is now available
                            semaphore.signal()
                        }
                        
                        do {
                            let embedding = try self.getEmbedding(for: text)
                            let similarity = self.cosineSimilarity(queryEmbedding, embedding)
                            
                            // Use the serial queue for thread-safe access to the array
                            resultsQueue.sync {
                                topChunkScores.append(Double(similarity))
                                
                                // Sort and get top similarities
                                topChunkScores.sort(by: >)
                                if topChunkScores.count > maxChunks {
                                    topChunkScores.removeLast()
                                }
                            }
                        } catch {
                            print("Error computing embedding: \(error)")
                        }
                        
                        progressCallback?((Double(index) / Double(doc.count)), "Computing \(index+1)/\(doc.count) document embeddings...\(text.prefix(30))")
                    }
                }
            }
            
            group.wait()
            let result = topChunkScores.reduce(0.0) { $0 + $1 } / Double(topChunkScores.count)
            return result
        } catch {
            logger.log("Failed to compute query embedding: \(error.localizedDescription)", level: .error)
            return 0.0
        }
    }
    
    /// Compute similarities between one query and multiple texts in batch with reduced memory usage
    func computeBatchSimilarity(_ query: String, _ docs: [[String]], maxChunks: Int, threshold: Double = 512, progressCallback: ((Double, String) -> Void)? = nil) -> [Double] {
        do {
            let queryEmbedding = try getEmbedding(for: query)
            progressCallback?(0.1, "Computed query embedding")
            
            // Process in smaller batches to reduce memory usage
            var results: [Double] = Array(repeating: 0.0, count: docs.count)
            
            for (i, doc) in docs.enumerated() {
                progressCallback?(0.1 + 0.7 * Double(i) / Double(docs.count), "Processing batch \(i)/\(docs.count)")

                let docCount = doc.reduce(0) { $0 + $1.count }
                // Calculate similarities for doc
                let similarity = computeDocumentSimilarity(query, doc, maxChunks: maxChunks, progressCallback: progressCallback)
                let adjustedSimilarity = Double(similarity) * min(1.0, Double(docCount) / threshold)
                results[i] = adjustedSimilarity
            }
            
            return results
        } catch {
            logger.log("Failed to compute query embedding: \(error.localizedDescription)", level: .error)
            return Array(repeating: 0.0, count: docs.count)
        }
    }
}

enum EmbeddingError: Error {
    case modelNotLoaded
    case predictionFailed
    case invalidInput
    case modelNotFound
    case modelLoadFailed

    var localizedDescription: String {
        switch self {
        case .modelNotLoaded:
            return "SentenceBERT model not loaded"
        case .predictionFailed:
            return "Failed to get prediction from model"
        case .invalidInput:
            return "Invalid input for embedding"
        case .modelNotFound:
            return "SentenceBERT model not found"
        case .modelLoadFailed:
            return "Failed to load SentenceBERT model"
        }
    }
}
