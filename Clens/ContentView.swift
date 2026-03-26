import SwiftUI
import Photos
import Combine
import StoreKit

struct ContentView: View {
    @StateObject private var viewModel = PhotoScannerViewModel()
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    
    private enum GridType {
        case unmatched, notInLocal
    }
    
    private enum ScrollDirection {
        case up, down
    }
    
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var dragInitialAssetId: String? = nil
    @State private var isSelectingInDrag: Bool = true
    @State private var currentDragLocation: CGPoint? = nil
    @State private var currentDragType: GridType? = nil
    @State private var isSelectMode: Bool = false
    @State private var selectedAlbumGroup: AlbumGroup? = nil
    @State private var isShowingGuide: Bool = false
    
    @Environment(\.requestReview) var requestReview
    
    @State private var scannerPhaseIndex = 0
    private let scannerPhases = [
        "AIコア オンライン...",
        "スマートスキャン実行中...",
        "画像の特徴を分析中...",
        "類似パターンを検出中...",
        "メタデータを統合中..."
    ]
    @State private var scanRotation: Double = 0.0
    
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
        .overlay {
            if viewModel.isShowingSuccessMessage {
                SuccessPopupView(viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $isShowingGuide) {
            SharedAlbumGuideView {
                // ガイドの最終ステップから「スキャン開始」ボタンを押した時
                Task { await viewModel.startScan() }
            }
        }
        .fullScreenCover(isPresented: .init(get: { !hasCompletedOnboarding }, set: { _ in })) {
            OnboardingView()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            // スキャン完了後に初回 or 重複少ない場合はガイドを表示
            if !isScanning && viewModel.hasCompletedFirstScan {
                let shouldShowGuide = shouldShowSharedAlbumGuide()
                if shouldShowGuide {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isShowingGuide = true
                    }
                }
            }
        }
        .onChange(of: viewModel.isShowingSuccessMessage) { _, isShowing in
            if isShowing {
                // ハッピーモーメント（削除/保存の成功直後）にレビューをリクエスト
                // タイミング: 1回目, 5回目, その後20回ごと（かつ前回から30日以上経過）
                let count = viewModel.totalActionsPerformed
                let shouldRequest = (count == 1) || (count == 5) || (count > 5 && (count - 5) % 20 == 0)
                if shouldRequest {
                    let daysSinceLast = (Date().timeIntervalSince1970 - viewModel.lastReviewRequestDate) / 86400
                    if viewModel.lastReviewRequestDate == 0 || daysSinceLast >= 30 {
                        viewModel.lastReviewRequestDate = Date().timeIntervalSince1970
                        requestReview()
                    }
                }
            }
        }
    }
    
    // MARK: - Guide Logic
    
    /// ガイドを表示すべきか判定
    /// - 初回スキャン後は必ず表示
    /// - 重複が全体の10%未満かざ10件以下の場合も表示
    private func shouldShowSharedAlbumGuide() -> Bool {
        let totalLocal = viewModel.unmatchedAssets.count + viewModel.matches.count
        let matchCount = viewModel.matches.count
        // 初回スキャン完了後は必ず表示（totalScanCount はスキャン完了時に +1 される）
        if viewModel.totalScanCount == 1 { return true }
        // 重複が0件
        if matchCount == 0 { return true }
        // 重複が少ない（10件以下 かつ 全体の10%未満）
        if totalLocal > 0 && matchCount <= 10 && Double(matchCount) / Double(totalLocal) < 0.1 { return true }
        return false
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private var headerView: some View {
        HStack {
            Text("Clens")
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
        .padding(.horizontal)
        .padding(.top)
        
        if viewModel.displayMode != .duplicates && (!viewModel.unmatchedAssets.isEmpty || !viewModel.groupedMissingAssets.isEmpty) {
            // Include a condition that we're either not in NotInLocal, or we ARE in NotInLocal but an album is selected
            if viewModel.displayMode == .unmatched || (viewModel.displayMode == .notInLocal && selectedAlbumGroup != nil) {
                HStack {
                    Spacer()
                    Button {
                        HapticManager.shared.trigger(.light)
                        withAnimation {
                            isSelectMode.toggle()
                            if !isSelectMode {
                                // Clear selections when exiting select mode
                                if viewModel.displayMode == .unmatched {
                                    viewModel.selectedUnmatchedAssetIds.removeAll()
                                } else {
                                    viewModel.selectedMissingAssetIds.removeAll()
                                }
                            }
                        }
                    } label: {
                        Text(isSelectMode ? "キャンセル" : "選択")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                ZStack {
                                    if isSelectMode {
                                        Color.gray.opacity(0.3)
                                    } else {
                                        DesignConstants.primaryGradient
                                    }
                                }
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
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
                
                // Radar Line
                Circle()
                    .trim(from: 0, to: 0.1)
                    .stroke(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 30, lineCap: .round))
                    .rotationEffect(.degrees(scanRotation))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: scanRotation)
                    .onAppear {
                        scanRotation = 360
                    }
                
                VStack {
                    if #available(iOS 17.0, *) {
                        Image(systemName: "cpu")
                            .font(.system(size: 32))
                            .foregroundStyle(DesignConstants.primaryGradient)
                            .symbolEffect(.pulse)
                            .padding(.bottom, 4)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 32))
                            .foregroundStyle(DesignConstants.primaryGradient)
                            .padding(.bottom, 4)
                    }
                        
                    Text("\(Int(Double(viewModel.processedCount) / Double(max(1, viewModel.totalCount)) * 100))%")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("\(viewModel.processedCount) / \(viewModel.totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 240, height: 240)
            .padding(40)
            
            Text(scannerPhases[scannerPhaseIndex])
                .font(.headline)
                .foregroundColor(.secondary)
                .animation(.easeInOut, value: scannerPhaseIndex)
                .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                    scannerPhaseIndex = (scannerPhaseIndex + 1) % scannerPhases.count
                }
            
            // Privacy Badge
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                Text("全ての解析はデバイス内で完結します")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.1))
            .foregroundColor(.green)
            .cornerRadius(20)
            .padding(.top, 10)
            
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
                
                Image(systemName: viewModel.hasScannedThisSession ? "photo.on.rectangle.angled" : "sparkles")
                    .font(.system(size: 60))
                    .foregroundStyle(DesignConstants.primaryGradient)
            }

            VStack(spacing: 8) {
                if viewModel.hasScannedThisSession {
                    Text("共有アルバムが見つかりませんでした👀")
                        .font(.title2.bold())
                    Text("共有アルバムを使い始めると\n無料でiPhoneの容量を大幅に節約できます！")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("写真を整理して空き容量を増やしましょう")
                        .font(.title2.bold())
                    Text("重複した写真を見つけて、\nストレージに余裕を持たせましょう。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // 共有アルバムガイドバナー
            if viewModel.hasScannedThisSession {
                Button {
                    HapticManager.shared.trigger(.medium)
                    isShowingGuide = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("📱 無料で容量を節約する裏技を見る")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                            Text("共有アルバムの使い方を図解で解説 →")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        LinearGradient(colors: [Color.orange.opacity(0.25), Color.yellow.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yellow.opacity(0.4), lineWidth: 1))
                }
                .padding(.horizontal, 24)
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
            .padding(.top, 4)
            
            Spacer()
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            Picker("表示モード", selection: $viewModel.displayMode) {
                Text("容量を空ける (\(viewModel.matches.count))").tag(DisplayMode.duplicates)
                Text("端末に救出 (\(viewModel.missingFromLocalAssets.count))").tag(DisplayMode.notInLocal)
                if viewModel.isShowingUnmatched {
                    Text("未共有 (\(viewModel.unmatchedAssets.count))").tag(DisplayMode.unmatched)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: viewModel.displayMode) { _, _ in
                // Reset states when changing tabs
                isSelectMode = false
                selectedAlbumGroup = nil
            }
            .onChange(of: viewModel.isShowingUnmatched) { _, isShowing in
                // トグルをOFFにした時に未共有タブを表示中なら duplicates に戻す
                if !isShowing && viewModel.displayMode == .unmatched {
                    viewModel.displayMode = .duplicates
                }
            }
            
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
            VStack(spacing: 12) {
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
                
                if !viewModel.matches.isEmpty {
                    HStack {
                        let anySelected = viewModel.matches.contains { $0.isSelected }
                        Button(action: {
                            HapticManager.shared.trigger(.light)
                            viewModel.setAllSelection(selected: !anySelected)
                        }) {
                            Text(anySelected ? "すべて選択解除" : "すべて選択")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        
                        // 無料枠の残り枚数表示
                        if !viewModel.isPremium {
                            let remaining = max(0, 50 - viewModel.todayCleanedCount)
                            HStack(spacing: 4) {
                                Image(systemName: remaining > 0 ? "checkmark.circle" : "lock.fill")
                                    .font(.caption)
                                if remaining > 0 {
                                    Text("今日あと\(remaining)枚無料")
                                } else {
                                    Text("本日の無料枠終了")
                                }
                                
                                if viewModel.matches.count > 50 {
                                    Text("(残り\(max(0, viewModel.matches.count - remaining))枚はPROで解放)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.caption.bold())
                            .foregroundColor(remaining > 10 ? .secondary : .orange)
                        }
                    }
                }
                
                // ── PRO 固定バナー（常に最上部に表示）──
                if !viewModel.isPremium && viewModel.matches.count > viewModel.remainingFreeCount {
                    let lockedBytes = viewModel.matches.dropFirst(viewModel.remainingFreeCount).reduce(Int64(0)) { $0 + $1.fileSize }
                    Button {
                        HapticManager.shared.trigger(.medium)
                        viewModel.isShowingPaywall = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.open.fill")
                                .font(.title3)
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("さらに \(lockedBytes.formatBytes()) の容量を空けられます")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.leading)
                                Text("PROにアップグレードして全て解放 →")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [Color.blue.opacity(0.5), Color.purple.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))

            
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.matches) { match in
                        MatchCardView(match: match) {
                            HapticManager.shared.trigger(.light)
                            viewModel.toggleSelection(match: match)
                        }
                    }
                }
                .padding()
            }
            
            cleanupActionButton
        }
    }
    
    @State private var autoScrollProxy: ScrollViewProxy? = nil
    @State private var autoScrollTimer: Timer? = nil
    
    private var unmatchedGrid: some View {
        VStack(alignment: .leading) {
            Text("この端末にはありますが、共有アルバムに同じ写真が見つかりませんでした。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            GeometryReader { outerGeo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                            ForEach(viewModel.unmatchedAssets, id: \.localIdentifier) { asset in
                                ZStack(alignment: .topTrailing) {
                                    ThumbnailView(asset: asset)
                                    
                                    if viewModel.selectedUnmatchedAssetIds.contains(asset.localIdentifier) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .blue)
                                            .padding(4)
                                    }
                                }
                                .id(asset.localIdentifier)
                                .glassStyle()
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: FramePreferenceKey.self, value: [asset.localIdentifier: geo.frame(in: .named("grid"))])
                                    }
                                )
                                .onTapGesture {
                                    HapticManager.shared.trigger(.light)
                                    viewModel.toggleUnmatchedSelection(for: asset.localIdentifier)
                                }
                            }
                        }
                        .padding()
                        .onPreferenceChange(FramePreferenceKey.self) { frames in
                            self.itemFrames = frames
                        }
                    }
                    .coordinateSpace(name: "grid")
                    .onAppear {
                        scrollViewBounds = outerGeo.frame(in: .global)
                    }
                    .onChange(of: outerGeo.frame(in: .global)) { _, newFrame in
                        scrollViewBounds = newFrame
                    }
                    .gesture(
                        isSelectMode ? 
                        DragGesture(minimumDistance: 15, coordinateSpace: .named("grid"))
                            .onChanged { value in
                                handleDragChanged(value, proxy: proxy, type: .unmatched, viewHeight: outerGeo.size.height)
                            }
                            .onEnded { _ in
                                handleDragEnded()
                            }
                        : nil
                    )
                }
            }
        }
    }
    
    private var notInLocalGrid: some View {
        VStack(alignment: .leading) {
            Text("共有アルバムにありますが、この端末内には見つかりませんでした。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            if let album = selectedAlbumGroup {
                albumDetailGrid(album: album)
            } else {
                albumListView
            }
        }
    }
    
    private var albumListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.groupedMissingAssets) { group in
                    Button {
                        HapticManager.shared.trigger(.light)
                        withAnimation {
                            selectedAlbumGroup = group
                        }
                    } label: {
                        HStack(spacing: 16) {
                            if let firstAsset = group.assets.first {
                                ThumbnailView(asset: firstAsset)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 60, height: 60)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("\(group.assets.count)枚")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
    
    private func albumDetailGrid(album: AlbumGroup) -> some View {
        VStack(spacing: 0) {
            // Album Detail Header
            HStack {
                Button {
                    HapticManager.shared.trigger(.light)
                    withAnimation {
                        selectedAlbumGroup = nil
                        isSelectMode = false // exit select mode when going back
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("アルバム一覧")
                    }
                    .foregroundColor(.blue)
                }
                Spacer()
                Text(album.title)
                    .font(.headline)
                Spacer()
                // Placeholder to balance the HStack
                Text("アルバム一覧").opacity(0)
            }
            .padding()
            
            GeometryReader { outerGeo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                            ForEach(album.assets, id: \.localIdentifier) { asset in
                                ZStack(alignment: .topTrailing) {
                                    ThumbnailView(asset: asset)
                                    
                                    if viewModel.selectedMissingAssetIds.contains(asset.localIdentifier) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .blue)
                                            .padding(8)
                                    } else if isSelectMode {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.white)
                                            .padding(8)
                                    }
                                }
                                .id(asset.localIdentifier)
                                .glassStyle()
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: FramePreferenceKey.self, value: [asset.localIdentifier: geo.frame(in: .named("grid"))])
                                    }
                                )
                                .onTapGesture {
                                    if isSelectMode {
                                        HapticManager.shared.trigger(.light)
                                        viewModel.toggleMissingSelection(for: asset.localIdentifier)
                                    }
                                }
                            }
                        }
                        .padding()
                        .onPreferenceChange(FramePreferenceKey.self) { frames in
                            self.itemFrames = frames
                        }
                    }
                    .coordinateSpace(name: "grid")
                    .onAppear {
                        scrollViewBounds = outerGeo.frame(in: .global)
                    }
                    .onChange(of: outerGeo.frame(in: .global)) { _, newFrame in
                        scrollViewBounds = newFrame
                    }
                    .gesture(
                        isSelectMode ? 
                        DragGesture(minimumDistance: 15, coordinateSpace: .named("grid"))
                            .onChanged { value in
                                handleDragChanged(value, proxy: proxy, type: .notInLocal, viewHeight: outerGeo.size.height)
                            }
                            .onEnded { _ in
                                handleDragEnded()
                            }
                        : nil
                    )
                }
            }
            
            if isSelectMode {
                cleanupActionButton
            }
        }
    }
    
    
    private func handleDragChanged(_ value: DragGesture.Value, proxy: ScrollViewProxy, type: GridType, viewHeight: CGFloat) {
        currentDragLocation = value.location
        currentDragType = type
        
        if dragInitialAssetId == nil {
            if let initialId = findId(at: value.startLocation) {
                dragInitialAssetId = initialId
                let isSelected = type == .unmatched ? 
                    viewModel.selectedUnmatchedAssetIds.contains(initialId) : 
                    viewModel.selectedMissingAssetIds.contains(initialId)
                isSelectingInDrag = !isSelected
                HapticManager.shared.selection()
            }
        }
        
        if let currentId = findId(at: value.location), let initialId = dragInitialAssetId {
            if type == .unmatched {
                viewModel.selectUnmatchedRange(fromId: initialId, toId: currentId, selected: isSelectingInDrag)
            } else {
                viewModel.selectMissingRange(fromId: initialId, toId: currentId, selected: isSelectingInDrag)
            }
        }
        
        // Auto-scroll logic
        handleAutoScroll(at: value.location, proxy: proxy, type: type, viewHeight: viewHeight)
    }
    
    private func handleDragEnded() {
        dragInitialAssetId = nil
        currentDragLocation = nil
        currentDragType = nil
        stopAutoScroll()
        // Do not remove itemFrames here, so they don't jump around on next drag start
    }
    
    @State private var scrollViewBounds: CGRect = .zero
    
    private func handleAutoScroll(at location: CGPoint, proxy: ScrollViewProxy, type: GridType, viewHeight: CGFloat) {
        let thresholdPercentage: CGFloat = 0.15
        let threshold = viewHeight * thresholdPercentage
        
        let relativeY = location.y
        
        if relativeY < threshold {
            let speed = (threshold - relativeY) / threshold
            startAutoScroll(direction: .up, proxy: proxy, type: type, speed: speed, viewHeight: viewHeight)
        } else if relativeY > viewHeight - threshold {
            let speed = (relativeY - (viewHeight - threshold)) / threshold
            startAutoScroll(direction: .down, proxy: proxy, type: type, speed: speed, viewHeight: viewHeight)
        } else {
            stopAutoScroll()
        }
    }
    
    private func startAutoScroll(direction: ScrollDirection, proxy: ScrollViewProxy, type: GridType, speed: CGFloat, viewHeight: CGFloat) {
        guard autoScrollTimer == nil else { return }
        
        // Use speed to adjust interval (0.01 to 0.1)
        let interval = 0.1 - (0.09 * max(0, min(1, speed)))
        
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak viewModel] _ in
            guard let viewModel = viewModel else { return }
            
            Task { @MainActor in
                // Expand selection during scroll if finger is held down
                if let loc = self.currentDragLocation, let t = self.currentDragType, let initialId = self.dragInitialAssetId {
                    if let currentId = self.findId(at: loc) {
                        if t == .unmatched {
                            viewModel.selectUnmatchedRange(fromId: initialId, toId: currentId, selected: self.isSelectingInDrag)
                        } else {
                            viewModel.selectMissingRange(fromId: initialId, toId: currentId, selected: self.isSelectingInDrag)
                        }
                    }
                }
                
                let assets = type == .unmatched ? viewModel.unmatchedAssets : viewModel.missingAssetsInUIOrder
                guard !assets.isEmpty else { return }
                
                let screenWidth = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
                let midX = self.scrollViewBounds.width > 0 ? self.scrollViewBounds.width / 2 : screenWidth / 2
                let checkPointY = direction == .up ? 60 : viewHeight - 60
                let currentId = self.findId(at: CGPoint(x: midX, y: checkPointY))
                
                if let cid = currentId, let index = assets.firstIndex(where: { $0.localIdentifier == cid }) {
                    let step = direction == .up ? -3 : 3
                    let nextIndex = max(0, min(assets.count - 1, index + step))
                    let nextId = assets[nextIndex].localIdentifier
                    
                    withAnimation(.linear(duration: interval)) {
                        proxy.scrollTo(nextId, anchor: direction == .up ? .top : .bottom)
                    }
                } else {
                    if direction == .up {
                        proxy.scrollTo(assets.first?.localIdentifier, anchor: .top)
                    } else {
                        proxy.scrollTo(assets.last?.localIdentifier, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }
    
    private func findId(at location: CGPoint) -> String? {
        itemFrames.first { _, rect in
            rect.contains(location)
        }?.key
    }
    
    @ViewBuilder
    private var cleanupActionButton: some View {
        if viewModel.displayMode == .notInLocal {
            saveToDeviceButton
        } else {
            let selectedCount = viewModel.matches.filter { $0.isSelected }.count
            let isOverLimit = !viewModel.isPremium && selectedCount > viewModel.remainingFreeCount
            
            Button(action: {
                HapticManager.shared.trigger(.medium)
                if isOverLimit {
                    viewModel.isShowingPaywall = true
                } else {
                    Task { await viewModel.performCleanup() }
                }
            }) {
                HStack {
                    if isOverLimit {
                        Image(systemName: "lock.fill")
                    } else {
                        Image(systemName: viewModel.cleanupMode == .delete ? "trash.fill" : "folder.fill.badge.plus")
                    }
                    
                    if viewModel.cleanupMode == .delete {
                        Text("\(selectedCount)枚を一括削除\(isOverLimit ? " (PROで解放)" : "")")
                    } else {
                        Text("\(selectedCount)枚をアルバムへ移動\(isOverLimit ? " (PROで解放)" : "")")
                    }
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    selectedCount == 0 ? AnyShapeStyle(Color.gray.opacity(0.3)) : (
                        isOverLimit ? AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)) : (
                            viewModel.cleanupMode == .delete ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.blue)
                        )
                    )
                )
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

// MARK: - ConfettiView

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var rotation: Double
    var color: Color
    var shape: Int // 0=circle, 1=rect
    var size: CGFloat
    var speed: Double
    var drift: CGFloat
}

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []
    @State private var isAnimating = false
    
    let colors: [Color] = [
        Color(red: 0.6, green: 0.8, blue: 1.0),   // pastel blue
        Color(red: 1.0, green: 0.7, blue: 0.8),   // pastel pink
        Color(red: 0.7, green: 1.0, blue: 0.8),   // pastel green
        Color(red: 1.0, green: 0.95, blue: 0.6),  // pastel yellow
        Color.white.opacity(0.9)
    ]
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { p in
                    Group {
                        if p.shape == 0 {
                            Circle()
                                .fill(p.color)
                                .frame(width: p.size, height: p.size)
                        } else {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(p.color)
                                .frame(width: p.size * 0.6, height: p.size)
                        }
                    }
                    .rotationEffect(.degrees(p.rotation))
                    .position(x: p.x, y: p.y)
                    .opacity(isAnimating ? 0 : 0.9)
                }
            }
            .onAppear {
                let count = 45
                particles = (0..<count).map { _ in
                    ConfettiParticle(
                        x: CGFloat.random(in: 0...geo.size.width),
                        y: CGFloat.random(in: -50 ... -10),
                        rotation: Double.random(in: 0...360),
                        color: colors.randomElement()!,
                        shape: Int.random(in: 0...1),
                        size: CGFloat.random(in: 6...14),
                        speed: Double.random(in: 1.2...2.4),
                        drift: CGFloat.random(in: -30...30)
                    )
                }
                withAnimation(.easeIn(duration: 2.5)) {
                    isAnimating = true
                    for i in particles.indices {
                        particles[i].y = geo.size.height + 60
                        particles[i].x += particles[i].drift
                        particles[i].rotation += Double.random(in: 180...540)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - SuccessPopupView


struct SuccessPopupView: View {
    @ObservedObject var viewModel: PhotoScannerViewModel
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
            
            // 紙吹雪（削除成功時のみ）
            if viewModel.lastActionType == .cleanup && isAnimating {
                ConfettiView()
                    .ignoresSafeArea()
            }
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(DesignConstants.primaryGradient)
                        .frame(width: 100, height: 100)
                        .blur(radius: isAnimating ? 20 : 0)
                        .opacity(isAnimating ? 0.5 : 0.8)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white, DesignConstants.primaryGradient)
                        .scaleEffect(isAnimating ? 1.0 : 0.5)
                }
                
                VStack(spacing: 8) {
                    if viewModel.lastActionType == .saveToLibrary {
                         Text("保存完了！")
                            .font(.title.bold())
                    } else {
                        Text("🎉 スッキリしました！")
                            .font(.title.bold())
                    }
                    
                    if viewModel.lastActionType == .saveToLibrary {
                         Text("\(viewModel.lastCleanupCount)枚の写真を端末に保存しました。")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        let action = viewModel.cleanupMode == .delete ? String(localized: "action_trash") : String(localized: "action_album")
                        Text("\(viewModel.lastCleanupCount)枚の写真を\(action)しました。")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if viewModel.lastActionType == .cleanup && viewModel.cleanupMode == .delete {
                         Text("\(viewModel.lastCleanupSavedBytes.formatBytes()) の空きができました！")
                            .font(.headline)
                            .foregroundStyle(DesignConstants.primaryGradient)
                            .padding(.top, 4)
                    }
                }
                
                HStack(spacing: 16) {
                    Button {
                        HapticManager.shared.trigger(.light)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            viewModel.isShowingSuccessMessage = false
                        }
                    } label: {
                        Text("OK")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.secondary.opacity(0.3))
                            .cornerRadius(16)
                    }
                    
                    Button {
                        HapticManager.shared.trigger(.light)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            viewModel.isShowingSuccessMessage = false
                        }
                        if let url = URL(string: "photos-redirect://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("写真アプリを開く")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(DesignConstants.primaryGradient)
                            .cornerRadius(16)
                    }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(24)
            .scaleEffect(isAnimating ? 1.0 : 0.8)
            .opacity(isAnimating ? 1.0 : 0.0)
            .onAppear {
                // 心地よい成功Haptic（ブルッ！）
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    isAnimating = true
                }
            }
        }
        .zIndex(100)
    }
}

// MARK: - MatchCardView

struct MatchCardView: View {
    let match: PhotoMatch
    let onToggle: () -> Void
    
    private func aiJudgmentLabel(_ percentage: Int) -> (text: String, color: Color) {
        if percentage >= 95 { return ("AI判定: 完全に一致 ✨", .green) }
        if percentage >= 80 { return ("AI判定: ほぼ一致 👀", .yellow) }
        return ("AI判定: 似ている写真 🔍", .orange)
    }

    var body: some View {
        let aiLabel = aiJudgmentLabel(match.similarityPercentage)
        VStack(spacing: 12) {
            HStack {
                Text(aiLabel.text)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(aiLabel.color.opacity(0.15))
                    .foregroundColor(aiLabel.color)
                    .cornerRadius(20)
                
                Spacer()
                
                Button(action: onToggle) {
                    Image(systemName: match.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(match.isSelected ? .blue : .secondary)
                }
            }
            
            HStack(spacing: 16) {
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        ThumbnailView(asset: match.localAsset)
                        // 削除予定バッジ
                        if match.isSelected {
                            Text("🗑️ 削除予定")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(6)
                                .padding(.bottom, 3)
                        }
                    }
                    Text("この端末")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary.opacity(0.5))
                
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        ThumbnailView(asset: match.sharedAsset)
                        // 保管済みバッジ
                        Text("✅ 保管済み")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .padding(.bottom, 3)
                    }
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
                    Label("AIの厳しさを調整", systemImage: "bolt.shield.fill")
                        .font(.headline)
                        .foregroundStyle(DesignConstants.primaryGradient)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("甘め（似た写真も検出）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(viewModel.aiSensitivity))%")
                                .font(.headline.monospacedDigit())
                            Spacer()
                            Text("厳格（完全一致のみ）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $viewModel.aiSensitivity, in: 0...100)
                            .accentColor(.blue)
                    }
                    .padding()
                    .glassStyle()
                    
                    Text("「甘め」にすると少しでも似ている写真を見つけます。「厳格」にするとほぼ同じ写真のみを見つけます。迷ったら真ん中がおすすめです。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
                
                Divider().background(Color.white.opacity(0.1)).padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: 12) {
                    Label("詳細表示", systemImage: "list.bullet.below.rectangle")
                        .font(.headline)
                        .foregroundStyle(DesignConstants.primaryGradient)
                    
                    Toggle(isOn: $viewModel.isShowingUnmatched) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("未共有の写真を表示")
                                .font(.subheadline)
                            Text("この端末にあるが、共有アルバムに未登録の写真")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.blue)
                    .padding()
                    .glassStyle()
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

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { (_, new) in new }
    }
}
