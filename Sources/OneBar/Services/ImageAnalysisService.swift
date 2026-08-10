import Foundation
import Vision

/// On-device OCR + QR detection via Apple Vision.
enum ImageAnalysisService {
    struct Result {
        var text: String?
        var qrPayload: String?
    }

    static func analyze(_ imageData: Data) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var result = Result()

                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                textRequest.usesLanguageCorrection = true

                let barcodeRequest = VNDetectBarcodesRequest()
                barcodeRequest.symbologies = [.qr]

                let handler = VNImageRequestHandler(data: imageData, options: [:])
                try? handler.perform([textRequest, barcodeRequest])

                if let observations = textRequest.results, !observations.isEmpty {
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { result.text = joined }
                }
                if let payload = barcodeRequest.results?.first?.payloadStringValue, !payload.isEmpty {
                    result.qrPayload = payload
                }

                continuation.resume(returning: result)
            }
        }
    }
}
