import SwiftUI

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
                            
                            Text("Clens PRO")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            
                            Text("制限を解除して、iPhoneのストレージを\n最大限まで解放しましょう。")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.top, 20)
                        
                        // Features List
                        VStack(spacing: 20) {
                            FeatureRow(icon: "infinity.circle.fill", title: "無制限の整理", description: "1日50枚の制限がなくなり、何枚でも整理可能になります。")
                            FeatureRow(icon: "bolt.fill", title: "最優先サポート", description: "開発者が優先的にご要望や不具合に対応します。")
                            FeatureRow(icon: "heart.fill", title: "開発の支援", description: "今後の新機能追加やアップデートの支援になります。")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                        
                        Spacer(minLength: 40)
                        
                        // Action Areas
                        VStack(spacing: 16) {
                            Button {
                                // Simulate Purchase
                                HapticManager.shared.notification(.success)
                                withAnimation {
                                    isPremium = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    if isPremium {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("アップグレード完了")
                                    } else {
                                        Text("PROにアップグレード")
                                        Text("¥480 / 買い切り")
                                            .font(.caption)
                                            .opacity(0.8)
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
                                // Simulate Restore
                                HapticManager.shared.notification(.success)
                                isPremium = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    dismiss()
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
