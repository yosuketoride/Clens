import XCTest
@testable import SharedAlbumCleaner

// MARK: - Int64 formatBytes

final class Int64FormatBytesTests: XCTestCase {

    func testFormatBytesShowsMB() {
        let oneMB: Int64 = 1_048_576 // 1 MB
        XCTAssertTrue(oneMB.formatBytes().contains("MB"), "1 MB should display as MB")
    }

    func testFormatBytesShowsGB() {
        let oneGB: Int64 = 1_073_741_824 // 1 GB
        XCTAssertTrue(oneGB.formatBytes().contains("GB"), "1 GB should display as GB")
    }

    func testFormatBytesNeverEmpty() {
        XCTAssertFalse((0 as Int64).formatBytes().isEmpty)
    }

    func testFormatBytesSmallShowsKB() {
        let oneKB: Int64 = 1_024
        XCTAssertTrue(oneKB.formatBytesSmall().contains("KB"), "1 KB should display as KB")
    }

    func testFormatBytesSmallShowsMB() {
        let oneMB: Int64 = 1_048_576
        XCTAssertTrue(oneMB.formatBytesSmall().contains("MB"), "1 MB should display as MB")
    }

    func testFormatBytesSmallNeverEmpty() {
        XCTAssertFalse((512 as Int64).formatBytesSmall().isEmpty)
    }
}

// MARK: - CleanupMode

final class CleanupModeTests: XCTestCase {

    func testDeleteRawValue() {
        XCTAssertEqual(CleanupMode.delete.rawValue, "delete")
    }

    func testMoveToAlbumRawValue() {
        XCTAssertEqual(CleanupMode.moveToAlbum.rawValue, "moveToAlbum")
    }

    func testRawValueInitDelete() {
        XCTAssertEqual(CleanupMode(rawValue: "delete"), .delete)
    }

    func testRawValueInitMoveToAlbum() {
        XCTAssertEqual(CleanupMode(rawValue: "moveToAlbum"), .moveToAlbum)
    }

    func testRawValueInitUnknownReturnsNil() {
        XCTAssertNil(CleanupMode(rawValue: "unknown"))
    }
}

// MARK: - HashCacheService

final class HashCacheServiceTests: XCTestCase {

    override func setUp() async throws {
        await HashCacheService.shared.clearCache()
    }

    func testSaveAndRetrieveHash() async {
        let id = "test-\(UUID().uuidString)"
        let hash: UInt64 = 0xDEADBEEF12345678
        let brightness = 128

        await HashCacheService.shared.saveHash(hash, brightness: brightness, filename: "test.jpg", for: id)

        let result = await HashCacheService.shared.getHash(for: id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hash, hash)
        XCTAssertEqual(result?.brightness, brightness)
        XCTAssertEqual(result?.filename, "test.jpg")
    }

    func testSaveWithNilFilename() async {
        let id = "test-nil-\(UUID().uuidString)"
        await HashCacheService.shared.saveHash(42, brightness: 50, filename: nil, for: id)

        let result = await HashCacheService.shared.getHash(for: id)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.filename)
    }

    func testGetAllHashesContainsSaved() async {
        let id1 = "all-id1-\(UUID().uuidString)"
        let id2 = "all-id2-\(UUID().uuidString)"

        await HashCacheService.shared.saveHash(111, brightness: 50, filename: nil, for: id1)
        await HashCacheService.shared.saveHash(222, brightness: 100, filename: "img.heic", for: id2)

        let all = await HashCacheService.shared.getAllHashes()
        XCTAssertEqual(all[id1]?.hash, 111)
        XCTAssertEqual(all[id2]?.hash, 222)
    }

    func testClearCacheEmptiesEntries() async {
        let id = "clear-\(UUID().uuidString)"
        await HashCacheService.shared.saveHash(999, brightness: 80, filename: nil, for: id)
        await HashCacheService.shared.clearCache()

        let result = await HashCacheService.shared.getHash(for: id)
        XCTAssertNil(result)

        let all = await HashCacheService.shared.getAllHashes()
        XCTAssertTrue(all.isEmpty)
    }

    func testOverwriteExistingHash() async {
        let id = "overwrite-\(UUID().uuidString)"
        await HashCacheService.shared.saveHash(100, brightness: 10, filename: "old.jpg", for: id)
        await HashCacheService.shared.saveHash(200, brightness: 20, filename: "new.jpg", for: id)

        let result = await HashCacheService.shared.getHash(for: id)
        XCTAssertEqual(result?.hash, 200)
        XCTAssertEqual(result?.brightness, 20)
        XCTAssertEqual(result?.filename, "new.jpg")
    }
}

// MARK: - PhotoScannerViewModel selection logic

@MainActor
final class PhotoScannerViewModelSelectionTests: XCTestCase {

    func testInitialStateIsScanning() {
        let vm = PhotoScannerViewModel()
        XCTAssertFalse(vm.isScanning)
    }

    func testInitialMatchesEmpty() {
        let vm = PhotoScannerViewModel()
        XCTAssertTrue(vm.matches.isEmpty)
    }

    func testInitialDisplayModeIsDuplicates() {
        let vm = PhotoScannerViewModel()
        XCTAssertEqual(vm.displayMode, .duplicates)
    }

    func testToggleMissingSelectionAddsId() {
        let vm = PhotoScannerViewModel()
        vm.toggleMissingSelection(for: "asset-1")
        XCTAssertTrue(vm.selectedMissingAssetIds.contains("asset-1"))
    }

    func testToggleMissingSelectionRemovesIdOnSecondCall() {
        let vm = PhotoScannerViewModel()
        vm.toggleMissingSelection(for: "asset-1")
        vm.toggleMissingSelection(for: "asset-1")
        XCTAssertFalse(vm.selectedMissingAssetIds.contains("asset-1"))
    }

    func testToggleUnmatchedSelectionAddsId() {
        let vm = PhotoScannerViewModel()
        vm.toggleUnmatchedSelection(for: "unmatched-1")
        XCTAssertTrue(vm.selectedUnmatchedAssetIds.contains("unmatched-1"))
    }

    func testSelectMissingAssetsSelectsAll() {
        let vm = PhotoScannerViewModel()
        let ids: Set<String> = ["id-a", "id-b", "id-c"]
        vm.selectMissingAssets(ids: ids, selected: true)
        XCTAssertTrue(vm.selectedMissingAssetIds.isSuperset(of: ids))
    }

    func testSelectMissingAssetsDeselectsPartial() {
        let vm = PhotoScannerViewModel()
        vm.selectMissingAssets(ids: ["id-a", "id-b", "id-c"], selected: true)
        vm.selectMissingAssets(ids: ["id-a", "id-b"], selected: false)
        XCTAssertFalse(vm.selectedMissingAssetIds.contains("id-a"))
        XCTAssertFalse(vm.selectedMissingAssetIds.contains("id-b"))
        XCTAssertTrue(vm.selectedMissingAssetIds.contains("id-c"))
    }

    func testRemainingFreeCountWhenPremium() {
        let vm = PhotoScannerViewModel()
        vm.isPremium = true
        XCTAssertEqual(vm.remainingFreeCount, Int.max)
    }

    func testRemainingFreeCountNonPremium() {
        let vm = PhotoScannerViewModel()
        vm.isPremium = false
        vm.dailyFreeLimit = 50
        vm.todayCleanedCount = 10
        XCTAssertEqual(vm.remainingFreeCount, 40)
    }

    func testRemainingFreeCountDoesNotGoNegative() {
        let vm = PhotoScannerViewModel()
        vm.isPremium = false
        vm.dailyFreeLimit = 50
        vm.todayCleanedCount = 70 // exceeded
        XCTAssertEqual(vm.remainingFreeCount, 0)
    }
}
