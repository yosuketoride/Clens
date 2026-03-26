import SwiftUI
import StoreKit
struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("isPremium") var isPremium: Bool = false
    
    var body: some View {
        ZStack {
            DesignConstants.backgroundDark.ignoresSafeArea()
            
            // Background Glow
            Circle()
                .fill(DesignConstants.primaryGradient)
                .frame(width: 400, height: 400)
                .blur(radius: 120)
                .opacity(0.15)
                .offset(y: -200)
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding()
                }
                
                ScrollView {
                    VStack(spacing: 30) {
                        // Title Area
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(DesignConstants.primaryGradient)
                                    .frame(width: 100, height: 100)
                                    .blur(radius: 20)
                                    .opacity(0.3)
                                
                                Image(systemName: "star.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundStyle(DesignConstants.primaryGradient)
                            }
                            
                            Text("Clens")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            
                            Text("1日50枚じゃ足りない！\n一気にストレージをスッキリさせませんか？")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.top, 20)
                        
                        // Features List
                        VStack(spacing: 20) {
                            FeatureRow(icon: "infinity.circle.fill", title: "⚡ 枚数制限なし", description: "一度に何百枚でもスッキリ！\nGB単位で容量を解放できます")
                            FeatureRow(icon: "tag.fill", title: "💰 ずっと使える買い切り版", description: "毎月の面倒なサブスク課金は不要。\n一度の購入で一生使えます")
                            FeatureRow(icon: "cup.and.saucer.fill", title: "☕ コーヒー1杯の価格", description: "一生「容量不足」のストレスから解放")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                        
                        Spacer(minLength: 40)
                        
                        // Action Areas
                        VStack(spacing: 16) {
                            Button {
                                Task {
                                    do {
                                        _ = try await StoreManager.shared.purchase()
                                        HapticManager.shared.notification(.success)
                                        // StoreManager updates isPremium automatically
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                            dismiss()
                                        }
                                    } catch {
                                        HapticManager.shared.notification(.error)
                                    }
                                }
                            } label: {
                                HStack {
                                    if isPremium {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("アップグレード完了")
                                    } else {
                                        Text("PROにアップグレード")
                                        if let product = StoreManager.shared.products.first {
                                            Text("\(product.displayPrice) / 買い切り")
                                                .font(.caption)
                                                .opacity(0.8)
                                        } else {
                                            Text("¥480 / 買い切り")
                                                .font(.caption)
                                                .opacity(0.8)
                                        }
                                    }
                                }
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(isPremium ? AnyShapeStyle(Color.green) : AnyShapeStyle(DesignConstants.primaryGradient))
                                .cornerRadius(16)
                                .shadow(color: isPremium ? .green.opacity(0.3) : .blue.opacity(0.3), radius: 10, y: 5)
                            }
                            .disabled(isPremium)
                            
                            Button {
                                Task {
                                    do {
                                        try await StoreManager.shared.restore()
                                        HapticManager.shared.notification(.success)
                                        if isPremium {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                                dismiss()
                                            }
                                        }
                                    } catch {
                                        HapticManager.shared.notification(.error)
                                    }
                                }
                            } label: {
                                Text("購入情報を復元する")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(DesignConstants.primaryGradient)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
