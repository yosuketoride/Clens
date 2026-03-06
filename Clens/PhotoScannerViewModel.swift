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

@MainActor
class PhotoScannerViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var matches: [PhotoMatch] = []
    @Published var unmatchedAssets: [PHAsset] = [] // 端末にあるが共有アルバムにない
    @Published var missingFromLocalAssets: [PHAsset] = [] // 共有アルバムにあるが端末にない
    @Published var processedCount = 0
    @Published var totalCount = 0
    @Published var totalSavedBytes: Int64 = 0
    @Published var isProcessing = false
    @Published var isShowingDeleteConfirmation = false
    @Published var isShowingSuccessMessage = false
    @Published var isShowingSettings = false
    @Published var lastCleanupCount = 0
    @Published var lastActionType: ActionType = .cleanup
    @Published var selectedMissingAssetIds: Set<String> = [] // 端末外タブでの選択
    @Published var displayMode: DisplayMode = .duplicates
    
    enum ActionType {
        case cleanup
        case saveToLibrary
    }
    
    // 設定関連
    @AppStorage("cleanupMode") var cleanupMode: CleanupMode = .delete
    @AppStorage("aiSensitivity") var aiSensitivity: Double = 50.0 {
        didSet {
            applyFiltering()
        }
    }
    
    // Monetization
    @AppStorage("isPremium") var isPremium: Bool = false
    @AppStorage("dailyFreeCleanupLimit") var dailyFreeLimit: Int = 50
    @AppStorage("todayCleanedCount") var todayCleanedCount: Int = 0
    @AppStorage("lastCleanupDate") var lastCleanupDateString: String = ""
    
    @Published var isShowingPaywall = false
    
    private var allFoundMatches: [PhotoMatch] = []
    private var allLocalAssets: [PHAsset] = []
    private var allSharedAssets: [PHAsset] = []
    
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
                sharedAssets: sharedAssets,
                customThreshold: threshold
            ) { [weak self] current, total in
                Task { @MainActor in
                    self?.processedCount = current
                }
            }
            
            self.allFoundMatches = results
            applyFiltering()
            
            logger.info("Scan completed. Found \(results.count) potential matches.")
        } catch {
            logger.error("Scan failed: \(error.localizedDescription)")
        }
        
        isScanning = false
    }
    
    private func applyFiltering() {
        let minPercentage = Int(aiSensitivity)
        let foundMatches = self.allFoundMatches
        let localAssets = self.allLocalAssets
        let sharedAssets = self.allSharedAssets
        
        Task.detached {
            let filtered = foundMatches.filter { $0.similarityPercentage >= minPercentage }
            
            let matchedLocalIds = Set(filtered.map { $0.localAsset.localIdentifier })
            let unmatched = localAssets.filter { !matchedLocalIds.contains($0.localIdentifier) }
            
            let matchedSharedIds = Set(filtered.map { $0.sharedAsset.localIdentifier })
            let missingLocal = sharedAssets.filter { !matchedSharedIds.contains($0.localIdentifier) }
            
            await MainActor.run {
                self.matches = filtered
                self.unmatchedAssets = unmatched
                self.missingFromLocalAssets = missingLocal
                self.updateStats()
            }
        }
    }
    
    // 統計情報の更新
    private func updateStats() {
        var savedBytes: Int64 = 0
        for match in matches where match.isSelected {
            savedBytes += match.fileSize
        }
        self.totalSavedBytes = savedBytes
    }
    
    // 選択状態のトグル
    func toggleSelection(for matchId: UUID) {
        if let index = matches.firstIndex(where: { $0.id == matchId }) {
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
    
    // 整理の実行（設定に基づいく）
    func performCleanup() async {
        let selectedAssets = matches.filter { $0.isSelected }.map { $0.localAsset }
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
            self.lastActionType = .cleanup
            self.isShowingSuccessMessage = true
            
            recordUsage(count: selectedAssets.count)
            
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
