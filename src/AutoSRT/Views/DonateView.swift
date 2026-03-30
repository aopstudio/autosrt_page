import SwiftUI

struct DonateView: View {
    @Environment(\.dismiss) var dismiss
    private let analytics = AnalyticsService.shared

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding()
            }

            Text("Support AutoSRT")
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack(spacing: 4) {
                Text(
                    "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"
                )
                .font(.subheadline)
                .foregroundColor(.secondary)

                Button(action: {
                    if let url = URL(
                        string: "https://github.com/yyaadet/autosrt_page/releases/?from=app")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Check for Updates")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            Text("If you find AutoSRT helpful, consider supporting its development")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 40) {
                VStack {
                    Image("alipay_qr")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )

                    Text("Alipay")
                        .font(.headline)
                        .foregroundColor(.blue)
                }

                VStack {
                    Image("wechat_qr")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        )

                    Text("WeChat Pay")
                        .font(.headline)
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical)

            Text("Thank you for your support! ❤️")
                .font(.title3)
                .foregroundColor(.secondary)

            Button(action: {
                if let url = URL(string: "https://github.com/yyaadet/autosrt_page/?from=autosrt") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("Contact Me")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            Spacer()
        }
        .frame(width: 800, height: 600)
        .onAppear {
            analytics.trackEvent(.donateViewOpened)
        }
    }
}

#Preview {
    DonateView()
}
