import Foundation
import Photos

enum PhotoLibraryError: Error {
    case permissionDenied
    case fetchFailed
}

final class PhotoLibraryService: Sendable {
    static let shared = PhotoLibraryService()
    private init() {}
    
    func checkPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
            }
        }
    }
    
    func fetchSharedAlbumPhotos() async throws -> [PHAsset] {
        guard await checkPermission() else { throw PhotoLibraryError.permissionDenied }
        
        return await Task.detached { () -> [PHAsset] in
            var sharedAssets: [PHAsset] = []
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            
            collections.enumerateObjects { collection, _, _ in
                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                
                assets.enumerateObjects { asset, _, _ in
                    sharedAssets.append(asset)
                }
            }
            return sharedAssets
        }.value
    }
    
    func fetchLocalPhotos(limit: Int? = nil) async throws -> [PHAsset] {
        guard await checkPermission() else { throw PhotoLibraryError.permissionDenied }
        
        return await Task.detached { () -> [PHAsset] in
            var localAssets: [PHAsset] = []
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let limit = limit {
                fetchOptions.fetchLimit = limit
            }
            
            let allPhotos = PHAsset.fetchAssets(with: fetchOptions)
            allPhotos.enumerateObjects { asset, _, _ in
                localAssets.append(asset)
            }
            return localAssets
        }.value
    }
    
    func getFileSize(for asset: PHAsset) async -> Int64 {
        return await withCheckedContinuation { continuation in
            let resources = PHAssetResource.assetResources(for: asset)
            if let resource = resources.first,
               let fileSize = resource.value(forKey: "fileSize") as? Int64 {
                continuation.resume(returning: fileSize)
            } else {
                continuation.resume(returning: 0)
            }
        }
    }
    
    func addAssetsToAlbum(_ assets: [PHAsset], albumName: String) async throws {
        guard await checkPermission() else { throw PhotoLibraryError.permissionDenied }
        let album = try await getOrCreateAlbum(named: albumName)
        
        try await PHPhotoLibrary.shared().performChanges {
            let addRequest = PHAssetCollectionChangeRequest(for: album)
            addRequest?.addAssets(assets as NSFastEnumeration)
        }
    }
    
    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard await checkPermission() else { throw PhotoLibraryError.permissionDenied }
        
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }
    }
    
    private func getOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title == %@", name)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        if let existing = collections.firstObject {
            return existing
        }
        
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        
        let newCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        guard let newAlbum = newCollections.firstObject else {
            throw PhotoLibraryError.fetchFailed
        }
        return newAlbum
    }
    
    func saveAssetsToLibrary(_ assets: [PHAsset]) async throws {
        guard await checkPermission() else { throw PhotoLibraryError.permissionDenied }
        
        for asset in assets {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let manager = PHImageManager.default()
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.isSynchronous = false
                
                manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard let data = data else {
                        continuation.resume(throwing: PhotoLibraryError.fetchFailed)
                        return
                    }
                    
                    Task {
                        do {
                            try await PHPhotoLibrary.shared().performChanges {
                                let request = PHAssetCreationRequest.forAsset()
                                request.addResource(with: .photo, data: data, options: nil)
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    func getOriginalFilename(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename
    }
}
