import Foundation
import Combine
import Photos
import os.log
import SwiftUI
struct PhotoMatch: Identifiable {
    let id = UUID()
    let localAsset: PHAsset
    let sharedAsset: PHAsset
    let similarityScore: Float // ハミング距離 (0に近いほど一致)
    let fileSize: Int64
    var isSelected: Bool = true // 整理対象として選択されているか
    
    // 一致度をパーセント(0-100)で計算
    var similarityPercentage: Int {
        // dHashの64bit中、何ビット一致しているか
        // 距離0なら100%、距離16なら75%といった簡易計算
        let score = (64.0 - Double(similarityScore)) / 64.0 * 100.0
        return Int(min(100, max(0, score)))
    }
}

enum DisplayMode {
    case duplicates
    case unmatched     // 端末にあるが、共有アルバムにない
    case notInLocal    // 共有アルバムにあるが、端末にない
}

enum CleanupMode: String {
    case delete = "delete"
    case moveToAlbum = "moveToAlbum"
}

struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    var assets: [PHAsset]
}

@MainActor
class PhotoScannerViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var matches: [PhotoMatch] = []
    @Published var unmatchedAssets: [PHAsset] = [] // 端末にあるが共有アルバムにない
    @Published var missingFromLocalAssets: [PHAsset] = [] // 共有アルバムにあるが端末にない (フラットリスト)
    @Published var groupedMissingAssets: [AlbumGroup] = [] // 共有アルバムにあるが端末にない (アルバム別)
    @Published var processedCount = 0
    @Published var totalCount = 0
    @Published var totalSavedBytes: Int64 = 0
    @Published var isProcessing = false
    @Published var isShowingDeleteConfirmation = false
    @Published var isShowingSuccessMessage = false
    @Published var isShowingSettings = false
    @Published var lastCleanupCount = 0
    @Published var lastCleanupSavedBytes: Int64 = 0
    @Published var lastActionType: ActionType = .cleanup
    @Published var selectedMissingAssetIds: Set<String> = [] // 端末外タブでの選択
    @Published var selectedUnmatchedAssetIds: Set<String> = [] // 未共有タブでの選択
    @Published var displayMode: DisplayMode = .duplicates
    
    enum ActionType {
        case cleanup
        case saveToLibrary
    }
    
    // 設定関連
    @AppStorage("cleanupMode") var cleanupMode: CleanupMode = .delete
    @AppStorage("aiSensitivity") var aiSensitivity: Double = 90.0 {
        didSet {
            applyFiltering()
        }
    }
    
    // Monetization
    @AppStorage("isPremium") var isPremium: Bool = false
    @AppStorage("dailyFreeCleanupLimit") var dailyFreeLimit: Int = 50
    @AppStorage("todayCleanedCount") var todayCleanedCount: Int = 0
    @AppStorage("lastCleanupDate") var lastCleanupDateString: String = ""
    
    @AppStorage("totalActionsPerformed") var totalActionsPerformed: Int = 0
    @AppStorage("lastReviewRequestDate") var lastReviewRequestDate: Double = 0
    @AppStorage("hasCompletedFirstScan") var hasCompletedFirstScan: Bool = false
    @Published var hasScannedThisSession: Bool = false
    @AppStorage("totalScanCount") var totalScanCount: Int = 0
    
    // 残り無料枠の計算
    var remainingFreeCount: Int {
        if isPremium { return Int.max }
        return max(0, dailyFreeLimit - todayCleanedCount)
    }
    
    @Published var isShowingPaywall = false
    @Published var isShowingUnmatched = false
    
    private var allFoundMatches: [PhotoMatch] = []
    private var allLocalAssets: [PHAsset] = []
    private var allSharedAssets: [SharedAsset] = []
    
    private let engine = ImageMatchingEngine()
    private let logger = Logger(subsystem: "com.example.SharedAlbumCleaner", category: "ViewModel")
    
    func requestPermissions() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in }
    }
    
    func startScan() async {
        guard !isScanning else { return }
        
        isScanning = true
        allFoundMatches.removeAll()
        allSharedAssets.removeAll()
        matches.removeAll()
        unmatchedAssets.removeAll()
        missingFromLocalAssets.removeAll()
        groupedMissingAssets.removeAll()
        selectedMissingAssetIds.removeAll()
        processedCount = 0
        totalSavedBytes = 0
        
        do {
            logger.info("Starting photo scan...")
            let sharedAssets = try await PhotoLibraryService.shared.fetchSharedAlbumPhotos()
            self.allSharedAssets = sharedAssets
            
            let localAssets = try await PhotoLibraryService.shared.fetchLocalPhotos()
            self.allLocalAssets = localAssets
            
            let total = localAssets.count
            self.totalCount = total
            
            // フィルタリングは後で行うため、スキャン時は十分にゆるい閾値で実行
            // 距離48 = 一致度25%。これ以上ゆるいものは実用的でないため。
            let threshold = 48 
            
            let results = try await engine.findMatches(
                localAssets: localAssets,
                sharedAssets: sharedAssets.map { $0.asset },
                customThreshold: threshold
            ) { [weak self] current, total in
                guard let self else { return }
                Task { @MainActor in
                    self.processedCount = current
                }
            }
            
            self.allFoundMatches = results
            applyFiltering()
            
            logger.info("Scan completed. Found \(results.count) potential matches.")
        } catch {
            logger.error("Scan failed: \(error.localizedDescription)")
        }
        
        isScanning = false
        totalScanCount += 1
        hasCompletedFirstScan = true
        hasScannedThisSession = true
    }
    
    private func applyFiltering() {
        let minPercentage = Int(aiSensitivity)
        let foundMatches = self.allFoundMatches
        let localAssets = self.allLocalAssets
        let sharedAssets = self.allSharedAssets
        
        let filtered = foundMatches.filter { $0.similarityPercentage >= minPercentage }
        
        let matchedLocalIds = Set(filtered.map { $0.localAsset.localIdentifier })
        let unmatched = localAssets.filter { !matchedLocalIds.contains($0.localIdentifier) }
        
        let matchedSharedIds = Set(filtered.map { $0.sharedAsset.localIdentifier })
        let missingLocalFull = sharedAssets.filter { !matchedSharedIds.contains($0.asset.localIdentifier) }
        
        let flatMissing = missingLocalFull.map { $0.asset }
        
        var dict: [String: AlbumGroup] = [:]
        for sa in missingLocalFull {
            if var group = dict[sa.albumId] {
                group.assets.append(sa.asset)
                dict[sa.albumId] = group
            } else {
                dict[sa.albumId] = AlbumGroup(id: sa.albumId, title: sa.albumTitle, assets: [sa.asset])
            }
        }
        let sortedGroups = dict.values.sorted { $0.title < $1.title }
        
        var uiOrder: [PHAsset] = []
        for group in sortedGroups {
            uiOrder.append(contentsOf: group.assets)
        }
        
        let freeLimit = remainingFreeCount
        self.matches = filtered.enumerated().map { index, match in
            var updatedMatch = match
            // 非プレミアムなら残り枠数まではデフォルト選択、それ以降は解除
            if !isPremium && index >= freeLimit {
                updatedMatch.isSelected = false
            } else {
                updatedMatch.isSelected = true
            }
            return updatedMatch
        }
        self.unmatchedAssets = unmatched
        self.missingFromLocalAssets = flatMissing
        self.groupedMissingAssets = sortedGroups
        self.missingAssetsInUIOrder = uiOrder
        self.updateStats()
    }
    
    // 端末外タブの表示順リスト
    @Published var missingAssetsInUIOrder: [PHAsset] = []
    
    // 統計情報の更新
    private func updateStats() {
        var savedBytes: Int64 = 0
        for match in matches where match.isSelected {
            savedBytes += match.fileSize
        }
        self.totalSavedBytes = savedBytes
    }
    
    // 選択状態のトグル
    func toggleSelection(match: PhotoMatch) {
        if let index = matches.firstIndex(where: { $0.id == match.id }) {
            matches[index].isSelected.toggle()
            updateStats()
        }
    }
    
    // 全選択/解除
    func setAllSelection(selected: Bool) {
        for i in 0..<matches.count {
            matches[i].isSelected = selected
        }
        updateStats()
    }
    
    // 端末外タブの選択トグル
    func toggleMissingSelection(for assetId: String) {
        if selectedMissingAssetIds.contains(assetId) {
            selectedMissingAssetIds.remove(assetId)
        } else {
            selectedMissingAssetIds.insert(assetId)
        }
    }
    
    // 端末外タブの一括選択・解除
    func selectMissingAssets(ids: Set<String>, selected: Bool) {
        if selected {
            selectedMissingAssetIds.formUnion(ids)
        } else {
            selectedMissingAssetIds.subtract(ids)
        }
    }
    
    // 端末外タブの範囲選択
    func selectMissingRange(fromId: String, toId: String, selected: Bool) {
        let allIds = missingAssetsInUIOrder.map { $0.localIdentifier }
        guard let startIndex = allIds.firstIndex(of: fromId),
              let endIndex = allIds.firstIndex(of: toId) else { return }
        
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let rangeIds = Set(allIds[lower...upper])
        
        selectMissingAssets(ids: rangeIds, selected: selected)
    }
    
    // 未共有タブの選択トグル
    func toggleUnmatchedSelection(for assetId: String) {
        if selectedUnmatchedAssetIds.contains(assetId) {
            selectedUnmatchedAssetIds.remove(assetId)
        } else {
            selectedUnmatchedAssetIds.insert(assetId)
        }
    }
    
    // 未共有タブの範囲選択
    func selectUnmatchedRange(fromId: String, toId: String, selected: Bool) {
        let allIds = unmatchedAssets.map { $0.localIdentifier }
        guard let startIndex = allIds.firstIndex(of: fromId),
              let endIndex = allIds.firstIndex(of: toId) else { return }
        
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let rangeIds = Set(allIds[lower...upper])
        
        if selected {
            selectedUnmatchedAssetIds.formUnion(rangeIds)
        } else {
            selectedUnmatchedAssetIds.subtract(rangeIds)
        }
    }
    
    // 整理の実行（設定に基づいく）
    func performCleanup() async {
        let selectedItems = matches.filter { $0.isSelected }
        let selectedAssets = selectedItems.map { $0.localAsset }
        let savedBytes = selectedItems.reduce(0) { $0 + $1.fileSize }
        let count = selectedAssets.count
        guard count > 0 else { return }
        
        if !canPerformAction(count: count) {
            isShowingPaywall = true
            return
        }
        
        isProcessing = true
        do {
            switch self.cleanupMode {
            case .delete:
                try await PhotoLibraryService.shared.deleteAssets(selectedAssets)
                // 削除したものをリストから取り除く
                self.matches.removeAll { $0.isSelected }
            case .moveToAlbum:
                try await PhotoLibraryService.shared.addAssetsToAlbum(selectedAssets, albumName: "SharedAlbum済")
                // 移動完了後、isSelectedなものをそのままにするか取り除くか
                // ここでは「整理済み」としてリストから消したほうが分かりやすいので消す方針にする
                self.matches.removeAll { $0.isSelected }
            }
            updateStats()
            
            // 成功メッセージ用の状態更新
            self.lastCleanupCount = selectedAssets.count
            self.lastCleanupSavedBytes = savedBytes
            self.lastActionType = .cleanup
            self.isShowingSuccessMessage = true
            
            recordUsage(count: selectedAssets.count)
            totalActionsPerformed += 1
            
            logger.info("Cleanup performed: \(self.cleanupMode.rawValue) for \(selectedAssets.count) assets.")
        } catch {
            logger.error("Cleanup failed: \(error.localizedDescription)")
        }
        isProcessing = false
    }
    
    // 共有アルバムから端末へ保存を実行
    func saveMissingToLibrary() async {
        let selectedAssets = missingFromLocalAssets.filter { selectedMissingAssetIds.contains($0.localIdentifier) }
        let count = selectedAssets.count
        guard count > 0 else { return }
        
        if !canPerformAction(count: count) {
            isShowingPaywall = true
            return
        }
        
        isProcessing = true
        do {
            try await PhotoLibraryService.shared.saveAssetsToLibrary(selectedAssets)
            
            // 保存したものをリストから消す、あるいは再スキャンの案内
            // ここでは簡易的に「端末内にある」ことになったのでリストから取り除く
            // (実際にはPhotoLibraryChangeObserverで検知して自動更新されるのが理想だが、ここでは手動で整合性を取る)
            
            // また、保存されたばかりのアセットはPhotoLibraryService.fetchLocalPhotosで
            // 次回から取得できるようになるため、本来は再スキャンが最も確実。
            // ユーザーを混乱させないよう、このタブからは消す。
            
            // 選択解除
            selectedMissingAssetIds.removeAll()
            
            // 成功メッセージ
            self.lastCleanupCount = selectedAssets.count
            self.lastActionType = .saveToLibrary
            self.isShowingSuccessMessage = true
            
            recordUsage(count: selectedAssets.count)
            totalActionsPerformed += 1
            
            logger.info("Saved \(selectedAssets.count) assets from shared album to local library.")
            
            // 再スキャンを促すか、自動で行う
            // ここでは状態の整合性のために簡易的に「取り除く」だけにする
            self.missingFromLocalAssets.removeAll { asset in
                selectedAssets.contains(where: { $0.localIdentifier == asset.localIdentifier })
            }
            
        } catch {
            logger.error("Save to library failed: \(error.localizedDescription)")
        }
        isProcessing = false
    }
    
    // Monetization Helpers
    private func canPerformAction(count: Int) -> Bool {
        if isPremium { return true }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        if lastCleanupDateString != today {
            todayCleanedCount = 0
            lastCleanupDateString = today
        }
        
        return (todayCleanedCount + count) <= dailyFreeLimit
    }
    
    private func recordUsage(count: Int) {
        if !isPremium {
            todayCleanedCount += count
        }
    }
}
