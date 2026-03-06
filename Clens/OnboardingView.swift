import SwiftUI

struct OnboardingSlide: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let iconName: String
    let gradient: LinearGradient
}

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @State private var currentPage = 0
    
    let slides = [
        OnboardingSlide(
            title: "Clensへようこそ",
            description: "共有アルバムを活用して、iPhoneのストレージを賢く、安全に整理しましょう。",
            iconName: "sparkles",
            gradient: DesignConstants.primaryGradient
        ),
        OnboardingSlide(
            title: "「整理対象」を見つける",
            description: "すでに共有アルバムにある写真を賢く検知。手元の重複した写真を安全に削除できます。",
            iconName: "square.stack.3d.up.fill",
            gradient: DesignConstants.secondaryGradient
        ),
        OnboardingSlide(
            title: "「保存忘れ」を防ぐ",
            description: "共有アルバムにはあるのに、端末に保存していない大切な写真を見つけ出して救出します。",
            iconName: "arrow.down.circle.fill",
            gradient: LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        OnboardingSlide(
            title: "安心して整理",
            description: "削除した写真は「最近削除した項目」に移動されるため、30日以内ならいつでも復元可能です。",
            iconName: "checkmark.shield.fill",
            gradient: LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    ]
    
    var body: some View {
        ZStack {
            DesignConstants.backgroundDark.ignoresSafeArea()
            
            // Background Glows
            Circle()
                .fill(slides[currentPage].gradient)
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .opacity(0.15)
                .offset(x: -100, y: -200)
                .animation(.easeInOut(duration: 0.8), value: currentPage)
            
            VStack {
                TabView(selection: $currentPage) {
                    ForEach(0..<slides.count, id: \.self) { index in
                        SlideView(slide: slides[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                // Custom Page Indicator
                HStack(spacing: 8) {
                    ForEach(0..<slides.count, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? AnyShapeStyle(slides[currentPage].gradient) : AnyShapeStyle(Color.white.opacity(0.2)))
                            .frame(width: index == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(), value: currentPage)
                    }
                }
                .padding(.bottom, 40)
                
                // Action Button
                Button {
                    if currentPage < slides.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        HapticManager.shared.notification(.success)
                        hasCompletedOnboarding = true
                    }
                } label: {
                    Text(currentPage == slides.count - 1 ? "はじめる" : "次へ")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(slides[currentPage].gradient)
                        .cornerRadius(16)
                        .padding(.horizontal, 40)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.bottom, 40)
            }
        }
    }
}

private struct SlideView: View {
    let slide: OnboardingSlide
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Icon with Glass Effect
            ZStack {
                Circle()
                    .fill(slide.gradient)
                    .frame(width: 160, height: 160)
                    .blur(radius: 40)
                    .opacity(0.2)
                
                Image(systemName: slide.iconName)
                    .font(.system(size: 80))
                    .foregroundStyle(slide.gradient)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 10)
            }
            .padding(.bottom, 20)
            
            VStack(spacing: 16) {
                Text(slide.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                
                Text(slide.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .lineSpacing(4)
            }
            
            Spacer()
        }
    }
}
