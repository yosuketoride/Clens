import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var viewModel = PhotoScannerViewModel()
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    
    var body: some View {
        ZStack {
            DesignConstants.backgroundDark.ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerView
                
                if viewModel.isScanning {
                    scannerDashboard
                } else if viewModel.matches.isEmpty && viewModel.unmatchedAssets.isEmpty {
                    emptyStateDashboard
                } else {
                    resultsView
                }
            }
        }
        .onAppear {
            viewModel.requestPermissions()
        }
        .alert(Text("重複写真を削除しますか？"), isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("cancel_button", role: .cancel) { }
            Button("delete_button", role: .destructive) {
                HapticManager.shared.trigger(.medium)
                Task { await viewModel.performCleanup() }
            }
        } message: {
            Text(LocalizedStringKey("cleanup_confirmation_msg"))
        }
        .alert(Text("完了"), isPresented: $viewModel.isShowingSuccessMessage) {
            Button("OK") { }
            Button("open_photos_button") {
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            if viewModel.lastActionType == .saveToLibrary {
                Text("saved_to_library_msg \(viewModel.lastCleanupCount)")
            } else {
                Text("cleaned_up_msg \(viewModel.lastCleanupCount) \(viewModel.cleanupMode == .delete ? String(localized: "action_trash") : String(localized: "action_album"))")
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingPaywall) {
            PaywallView()
        }
        .fullScreenCover(isPresented: .init(get: { !hasCompletedOnboarding }, set: { _ in })) {
            OnboardingView()
        }
    }
    
    // MARK: - Components
    
    private var headerView: some View {
        HStack {
            Text("Clens PRO")
                .font(.title2.bold())
                .foregroundStyle(DesignConstants.primaryGradient)
            
            Spacer()
            
            if (!viewModel.matches.isEmpty || !viewModel.unmatchedAssets.isEmpty) && !viewModel.isScanning {
                Button {
                    HapticManager.shared.trigger(.light)
                    viewModel.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 8)
                
                Button {
                    HapticManager.shared.trigger(.light)
                    Task { await viewModel.startScan() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
    
    private var scannerDashboard: some View {
        VStack {
            Spacer()
            
            ZStack {
                // Outer Glow
                Circle()
                    .stroke(DesignConstants.primaryGradient, lineWidth: 2)
                    .blur(radius: 10)
                    .scaleEffect(1.1)
                
                // Track
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 15)
                
                // Progress
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.processedCount) / CGFloat(max(1, viewModel.totalCount)))
                    .stroke(DesignConstants.primaryGradient, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: viewModel.processedCount)
                
                VStack {
                    Text("\(Int(Double(viewModel.processedCount) / Double(max(1, viewModel.totalCount)) * 100))%")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("\(viewModel.processedCount) / \(viewModel.totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 240, height: 240)
            .padding(40)
            
            Text("ライブラリを最適化中...")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var emptyStateDashboard: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(DesignConstants.primaryGradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: 40)
                    .opacity(0.3)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 60))
                    .foregroundStyle(DesignConstants.primaryGradient)
            }
            
            VStack(spacing: 8) {
                Text("写真を整理して空き容量を増やしましょう")
                    .font(.title2.bold())
                Text("重複した写真を見つけて、\nストレージに余裕を持たせましょう。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                HapticManager.shared.trigger(.medium)
                Task { await viewModel.startScan() }
            } label: {
                Text("スキャン開始")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(DesignConstants.primaryGradient)
                    .cornerRadius(16)
                    .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            
            Spacer()
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            Picker("表示モード", selection: $viewModel.displayMode) {
                Text("整理 (\(viewModel.matches.count))").tag(DisplayMode.duplicates)
                Text("未共有 (\(viewModel.unmatchedAssets.count))").tag(DisplayMode.unmatched)
                Text("端末外 (\(viewModel.missingFromLocalAssets.count))").tag(DisplayMode.notInLocal)
            }
            .pickerStyle(.segmented)
            .padding()
            
            switch viewModel.displayMode {
            case .duplicates:
                duplicateResultsList
            case .unmatched:
                unmatchedGrid
            case .notInLocal:
                notInLocalGrid
            }
        }
    }
    
    private var duplicateResultsList: some View {
        VStack(spacing: 0) {
            // Stats Bar
            HStack {
                VStack(alignment: .leading) {
                    Text("削減可能な容量")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(viewModel.totalSavedBytes.formatBytes())
                        .font(.headline)
                        .foregroundColor(.green)
                }
                Spacer()
                
                Picker("方法", selection: $viewModel.cleanupMode) {
                    Text("削除").tag(CleanupMode.delete)
                    Text("アルバム").tag(CleanupMode.moveToAlbum)
                }
                .pickerStyle(.menu)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
            .background(Color.white.opacity(0.05))
            
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.matches) { match in
                        MatchCardView(match: match) {
                            HapticManager.shared.trigger(.light)
                            viewModel.toggleSelection(for: match.id)
                        }
                    }
                }
                .padding()
            }
            
            cleanupActionButton
        }
    }
    
    private var unmatchedGrid: some View {
        VStack(alignment: .leading) {
            Text("この端末にはありますが、共有アルバムに同じ写真が見つかりませんでした。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                    ForEach(viewModel.unmatchedAssets, id: \.localIdentifier) { asset in
                        ThumbnailView(asset: asset)
                            .glassStyle()
                    }
                }
                .padding()
            }
        }
    }
    
    private var notInLocalGrid: some View {
        VStack(alignment: .leading) {
            Text("共有アルバムにありますが、この端末内には見つかりませんでした。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                    ForEach(viewModel.missingFromLocalAssets, id: \.localIdentifier) { asset in
                        ZStack(alignment: .topTrailing) {
                            ThumbnailView(asset: asset)
                                .onTapGesture {
                                    HapticManager.shared.trigger(.light)
                                    viewModel.toggleMissingSelection(for: asset.localIdentifier)
                                }
                            
                            if viewModel.selectedMissingAssetIds.contains(asset.localIdentifier) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white, .blue)
                                    .padding(4)
                            }
                        }
                        .glassStyle()
                    }
                }
                .padding()
            }
            
            cleanupActionButton
        }
    }
    
    @ViewBuilder
    private var cleanupActionButton: some View {
        if viewModel.displayMode == .notInLocal {
            saveToDeviceButton
        } else {
            let selectedCount = viewModel.matches.filter { $0.isSelected }.count
            
            Button(action: {
                if viewModel.cleanupMode == .delete {
                    viewModel.isShowingDeleteConfirmation = true
                } else {
                    HapticManager.shared.trigger(.medium)
                    Task { await viewModel.performCleanup() }
                }
            }) {
                HStack {
                    Image(systemName: viewModel.cleanupMode == .delete ? "trash.fill" : "folder.fill.badge.plus")
                    if viewModel.cleanupMode == .delete {
                        Text("\(selectedCount)枚を一括削除")
                    } else {
                        Text("\(selectedCount)枚をアルバムへ移動")
                    }
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedCount == 0 ? Color.gray.opacity(0.3) : (viewModel.cleanupMode == .delete ? Color.red : Color.blue))
                .cornerRadius(16)
            }
            .disabled(selectedCount == 0 || viewModel.isProcessing)
            .padding()
            .background(DesignConstants.backgroundDark)
        }
    }
    
    private var saveToDeviceButton: some View {
        let selectedCount = viewModel.selectedMissingAssetIds.count
        
        return Button(action: {
            HapticManager.shared.trigger(.medium)
            Task { await viewModel.saveMissingToLibrary() }
        }) {
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                Text("\(selectedCount)枚を端末に保存")
            }
            .font(.headline.bold())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(selectedCount == 0 ? Color.gray.opacity(0.3) : Color.blue)
            .cornerRadius(16)
        }
        .disabled(selectedCount == 0 || viewModel.isProcessing)
        .padding()
        .background(DesignConstants.backgroundDark)
    }
}

// MARK: - MatchCardView

struct MatchCardView: View {
    let match: PhotoMatch
    let onToggle: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text("AI Confidence: \(match.similarityPercentage)%")
                }
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(match.similarityPercentage > 95 ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                .foregroundColor(match.similarityPercentage > 95 ? .green : .orange)
                .cornerRadius(20)
                
                Spacer()
                
                Button(action: onToggle) {
                    Image(systemName: match.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(match.isSelected ? .blue : .secondary)
                }
            }
            
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    ThumbnailView(asset: match.localAsset)
                    Text("デバイス内")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary.opacity(0.5))
                
                VStack(spacing: 4) {
                    ThumbnailView(asset: match.sharedAsset)
                    Text("共有アルバム")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text(match.fileSize.formatBytesSmall())
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("Content matched")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .glassStyle()
    }
}

struct ThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
                    .onAppear {
                        loadThumbnail()
                    }
            }
        }
    }
    
    private func loadThumbnail() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        
        manager.requestImage(for: asset,
                             targetSize: CGSize(width: 160, height: 160),
                             contentMode: .aspectFill,
                             options: options) { result, _ in
            if let result = result {
                DispatchQueue.main.async {
                    self.image = result
                }
            }
        }
    }
}

// MARK: - SettingsSheet

struct SettingsSheet: View {
    @ObservedObject var viewModel: PhotoScannerViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            DesignConstants.backgroundDark.ignoresSafeArea()
            
            VStack(spacing: 24) {
                HStack {
                    Text("AI判定の設定")
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        HapticManager.shared.trigger(.light)
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top)
                
                VStack(alignment: .leading, spacing: 16) {
                    Label("AI判定のしきい値", systemImage: "bolt.shield.fill")
                        .font(.headline)
                        .foregroundStyle(DesignConstants.primaryGradient)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("低 (すべて拾う)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(viewModel.aiSensitivity))%")
                                .font(.headline.monospacedDigit())
                            Spacer()
                            Text("高 (厳格に判定)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $viewModel.aiSensitivity, in: 0...100)
                            .accentColor(.blue)
                    }
                    .padding()
                    .glassStyle()
                    
                    Text("しきい値を下げると、少しでも似ている写真を「重複」として検知します。上げると、ほぼ同じ写真のみを「重複」とみなします。標準は70〜80%以上が推奨です。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
                
                Spacer()
                
                // Premium Banner
                if !viewModel.isPremium {
                    Button {
                        HapticManager.shared.trigger(.medium)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            viewModel.isShowingPaywall = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text("PROにアップグレードして制限を解除")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignConstants.primaryGradient, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal)
                } else {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("PRO版が有効です")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                Button {
                    HapticManager.shared.trigger(.light)
                    dismiss()
                } label: {
                    Text("完了")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(DesignConstants.primaryGradient)
                        .cornerRadius(16)
                }
                .padding(.bottom)
            }
            .padding()
        }
    }
}
