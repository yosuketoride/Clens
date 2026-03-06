import Foundation
import UIKit
import Photos
import Vision
import CoreImage
import os.log

final class ImageMatchingEngine: Sendable {
    private let logger = Logger(subsystem: "com.example.SharedAlbumCleaner", category: "Engine")
    
    // ハミング距離の基本閾値 (ファイル名不一致時)
    private let defaultThreshold: Int = 10 
    // ファイル名一致時の緩和閾値 (ファイル名が同じなら多少の加工を許容する)
    private let relaxedThreshold: Int = 16
    // 明るさの差の許容値 (0〜255)
    private let brightnessThreshold: Int = 40
    
    private struct AssetInfo {
        let asset: PHAsset
        let hash: UInt64
        let filename: String?
        let brightness: Int
    }
    
    private struct HashResult {
        let hash: UInt64
        let brightness: Int
        let filename: String?
    }

    func findMatches(
        localAssets: [PHAsset],
        sharedAssets: [PHAsset],
        customThreshold: Int? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [PhotoMatch] {
        let threshold = customThreshold ?? self.defaultThreshold
        
        let total = localAssets.count
        logger.info("Start high-speed parallel matching. (Total: \(total))")
        
        // 1. キャッシュを一括取得してアクターへのアクセス回数を最小限にする
        let fullCache = await HashCacheService.shared.getAllHashes()
        
        // 2. 共有アルバムのハッシュとメタデータを一括取得
        let sharedInfos: [AssetInfo] = try await withThrowingTaskGroup(of: AssetInfo?.self) { group in
            for asset in sharedAssets {
                group.addTask {
                    let result = await self.getDifferenceHashAndBrightness(for: asset, localCache: fullCache)
                    return result.map { AssetInfo(asset: asset, hash: $0.hash, filename: $0.filename, brightness: $0.brightness) }
                }
            }
            var results: [AssetInfo] = []
            for try await info in group {
                if let info = info { results.append(info) }
            }
            return results
        }
        
        // 3. 高速検索用にハッシュ値でグループ化 (O(1) 検索用)
        var sharedByHash: [UInt64: [AssetInfo]] = [:]
        for info in sharedInfos {
            sharedByHash[info.hash, default: []].append(info)
        }
        
        var allMatches: [PhotoMatch] = []
        let batchSize = 30 // メモリ使用量を抑えるためのバッチサイズ
        
        // 2. ローカル画像をバッチごとに並列処理
        for i in stride(from: 0, to: total, by: batchSize) {
            let end = min(i + batchSize, total)
            let batch = Array(localAssets[i..<end])
            
            let batchMatches = try await withThrowingTaskGroup(of: PhotoMatch?.self) { group in
                for localAsset in batch {
                    group.addTask {
                        let localResult = await self.getDifferenceHashAndBrightness(for: localAsset, localCache: fullCache)
                        guard let vLocalResult = localResult else { return nil }
                        
                        let localFilename = vLocalResult.filename
                        
                        // A. 完全一致 (Hashが同じ) を優先して検索 (O(1))
                        if let candidates = sharedByHash[vLocalResult.hash] {
                            for cand in candidates {
                                if abs(vLocalResult.brightness - cand.brightness) <= self.brightnessThreshold {
                                    let size = await PhotoLibraryService.shared.getFileSize(for: localAsset)
                                    return PhotoMatch(localAsset: localAsset, sharedAsset: cand.asset, similarityScore: 0, fileSize: size)
                                }
                            }
                        }
                        
                        // B. 曖昧一致の検索 (O(N) ループ)
                        var bestMatch: AssetInfo? = nil
                        var bestDist = 100
                        
                        for sharedInfo in sharedInfos {
                            let distance = (vLocalResult.hash ^ sharedInfo.hash).nonzeroBitCount
                            
                            // 明るさチェックとファイル名一致による閾値緩和
                            let isFilenameMatch = (localFilename != nil && localFilename == sharedInfo.filename)
                            let currentThreshold = isFilenameMatch ? max(self.relaxedThreshold, threshold) : threshold
                            
                            if distance <= currentThreshold {
                                if abs(vLocalResult.brightness - sharedInfo.brightness) <= self.brightnessThreshold {
                                    if distance < bestDist {
                                        bestDist = distance
                                        bestMatch = sharedInfo
                                    }
                                    if distance == 0 { break } // 既に候補は見つかっている
                                }
                            }
                        }
                        
                        if let best = bestMatch {
                            let size = await PhotoLibraryService.shared.getFileSize(for: localAsset)
                            return PhotoMatch(
                                localAsset: localAsset,
                                sharedAsset: best.asset,
                                similarityScore: Float(bestDist),
                                fileSize: size
                            )
                        }
                        return nil
                    }
                }
                
                var results: [PhotoMatch] = []
                for try await match in group {
                    if let m = match { results.append(m) }
                }
                return results
            }
            
            allMatches.append(contentsOf: batchMatches)
            progress(end, total)
        }
        
        // 全てのバッチが終了したらキャッシュを永続化
        await HashCacheService.shared.persistCache()
        
        return allMatches
    }
    
    private func getDifferenceHashAndBrightness(for asset: PHAsset, localCache: [String: HashCacheService.CachedHash]) async -> HashResult? {
        if let cached = localCache[asset.localIdentifier] {
            return HashResult(hash: cached.hash, brightness: cached.brightness, filename: cached.filename)
        }
        
        // キャッシュミス時はファイル名も取得して保存する
        let filename = PhotoLibraryService.shared.getOriginalFilename(for: asset)
        
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        
        return await withCheckedContinuation { continuation in
            let targetSize = CGSize(width: 64, height: 64)
            
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, info in
                guard let image = image, let cgImage = image.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let result = Self.calculateDifferenceHashAndBrightness(image: cgImage)
                
                Task {
                    await HashCacheService.shared.saveHash(result.hash, brightness: result.brightness, filename: filename, for: asset.localIdentifier)
                    continuation.resume(returning: HashResult(hash: result.hash, brightness: result.brightness, filename: filename))
                }
            }
        }
    }
    
    private static func calculateDifferenceHashAndBrightness(image: CGImage) -> HashResult {
        let size = CGSize(width: 9, height: 8)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 9, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return HashResult(hash: 0, brightness: 0, filename: nil)
        }
        
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(origin: .zero, size: size))
        
        guard let data = context.data else { return HashResult(hash: 0, brightness: 0, filename: nil) }
        let buffer = data.bindMemory(to: UInt8.self, capacity: 72)
        
        var hash: UInt64 = 0
        var bitIndex = 0
        var totalBrightness: Int = 0
        
        for y in 0..<8 {
            for x in 0..<8 {
                let left = buffer[y * 9 + x]
                let right = buffer[y * 9 + x + 1]
                
                if left > right {
                    hash |= (1 << bitIndex)
                }
                bitIndex += 1
                totalBrightness += Int(left)
            }
            // 各行の最後のピクセルも明るさ計算に含める
            totalBrightness += Int(buffer[y * 9 + 8])
        }
        
        return HashResult(hash: hash, brightness: totalBrightness / 72, filename: nil)
    }
}
import Foundation
import os.log

actor HashCacheService {
    static let shared = HashCacheService()
    
    struct CachedHash: Codable {
        let hash: UInt64
        let brightness: Int
        let filename: String?
    }
    
    private var cache: [String: CachedHash] = [:]
    private let logger = Logger(subsystem: "com.example.SharedAlbumCleaner", category: "HashCache")
    private let cacheFileName = "photo_hash_cache.json"
    
    private init() {
        self.cache = Self.loadCache()
    }
    
    private static var cacheURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("photo_hash_cache.json")
    }
    
    func getAllHashes() -> [String: CachedHash] {
        return cache
    }
    
    func getHash(for localIdentifier: String) -> CachedHash? {
        return cache[localIdentifier]
    }
    
    func saveHash(_ hash: UInt64, brightness: Int, filename: String?, for localIdentifier: String) {
        cache[localIdentifier] = CachedHash(hash: hash, brightness: brightness, filename: filename)
    }
    
    func persistCache() {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.cacheURL, options: .atomic)
            logger.info("Successfully persisted \(self.cache.count) hashes to disk.")
        } catch {
            logger.error("Failed to persist hash cache: \(error.localizedDescription)")
        }
    }
    
    private static func loadCache() -> [String: CachedHash] {
        let logger = Logger(subsystem: "com.example.SharedAlbumCleaner", category: "HashCache")
        do {
            let data = try Data(contentsOf: Self.cacheURL)
            let decoded = try JSONDecoder().decode([String: CachedHash].self, from: data)
            logger.info("Successfully loaded \(decoded.count) hashes from disk.")
            return decoded
        } catch {
            // It's normal to fail if there's no cache file yet
            logger.debug("No existing cache found or failed to load: \(error.localizedDescription)")
            return [:]
        }
    }
    
    func clearCache() {
        cache.removeAll()
        do {
            try FileManager.default.removeItem(at: Self.cacheURL)
            logger.info("Cleared on-disk cache.")
        } catch {
            logger.error("Failed to clear on-disk cache: \(error.localizedDescription)")
        }
    }
}
