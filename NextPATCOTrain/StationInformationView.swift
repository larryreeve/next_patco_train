import SwiftUI
import SafariServices
import WebKit

struct BrowserURL: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

struct StationInformationDestination: Identifiable {
    let stationName: String
    let url: URL

    var id: String {
        "\(stationName)|\(url.absoluteString)"
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let viewController = SFSafariViewController(url: url)
        viewController.dismissButtonStyle = .close
        viewController.isModalInPresentation = true
        return viewController
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum StationInformationLoadState: Equatable {
    case loading
    case loaded
    case failed
}

private struct StationInformationWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: StationInformationLoadState

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        loadState = .loading
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var loadState: StationInformationLoadState

        init(loadState: Binding<StationInformationLoadState>) {
            _loadState = loadState
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }
    }
}

private struct StationInformationBrowser: View {
    @Environment(\.openURL) private var openURL

    let url: URL

    @State private var loadState: StationInformationLoadState = .loading
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            StationInformationWebView(url: url, loadState: $loadState)
                .id(reloadID)

            if loadState == .loading {
                ProgressView("Loading station information...")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if loadState == .failed {
                ContentUnavailableView {
                    Label("Unable to Load Station Information", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection, then try again.")
                } actions: {
                    Button("Try Again") {
                        loadState = .loading
                        reloadID = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)

                    Button("Open in Safari") {
                        openURL(url)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color.white)
            }
        }
        .background(Color.white)
    }
}

struct StationInformationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let destination: StationInformationDestination

    var body: some View {
        NavigationStack {
            StationInformationBrowser(url: destination.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("\(destination.stationName) Station")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            openURL(destination.url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .accessibilityLabel("Open in Safari")

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close station information")
                    }
                }
        }
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
    }
}
