import SwiftUI
import VisionKit
import VtaMobileAgent

/// A full-screen QR scanner (VisionKit `DataScannerViewController`) that yields
/// the first valid ``PairingPayload`` it reads, then dismisses. Used by the
/// first-run "Pair with a QR code" flow in Settings.
struct PairingScanner: View {
    let onScan: (PairingPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerRepresentable { payload in
                        onScan(payload)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableViewCompat(
                        title: "Camera unavailable",
                        message:
                            "QR scanning needs a device with a camera. Enter the VTA details "
                            + "manually in Settings instead.")
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// UIKit bridge for `DataScannerViewController`, filtering to QR barcodes and
/// parsing each to a ``PairingPayload`` (ignoring non-pairing codes).
private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (PairingPayload) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighFrameRateTrackingEnabled: false)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (PairingPayload) -> Void
        private var done = false
        init(onPayload: @escaping (PairingPayload) -> Void) { self.onPayload = onPayload }

        func dataScanner(
            _ scanner: DataScannerViewController, didAdd added: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !done else { return }
            for item in added {
                if case let .barcode(barcode) = item,
                    let string = barcode.payloadStringValue,
                    let payload = PairingPayload.parse(string)
                {
                    done = true
                    scanner.stopScanning()
                    onPayload(payload)
                    return
                }
            }
        }
    }
}

/// A tiny back-compat stand-in for `ContentUnavailableView` (iOS 17+).
private struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
