import Foundation

/// An estimate of what a model will cost this Mac while it is loaded.
struct DeviceImpact {
    enum Severity: String {
        case negligible, light, moderate, heavy, excessive

        var label: String {
            switch self {
            case .negligible: return "Negligible"
            case .light:      return "Light"
            case .moderate:   return "Moderate"
            case .heavy:      return "Heavy"
            case .excessive:  return "Too large"
            }
        }
    }

    var severity: Severity
    var headline: String
    var detail: String
    /// Fraction of physical memory, where known.
    var memoryFraction: Double?

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    static var machineSummary: String {
        let gigabytes = Double(physicalMemory) / 1_073_741_824
        let cores = ProcessInfo.processInfo.processorCount
        return String(format: "%.0f GB RAM · %d cores", gigabytes, cores)
    }

    /// Apple's model is shared with the rest of the system and is not resident
    /// in this app, so the honest answer is "almost nothing".
    static var appleOnDevice: DeviceImpact {
        DeviceImpact(
            severity: .negligible,
            headline: "Negligible — the system owns this model",
            detail: "Shared with the rest of macOS. No download, and it does not count against this app's memory.",
            memoryFraction: nil)
    }

    /// - Parameter bytes: on-disk size of the model, which approximates the
    ///   resident size once loaded.
    static func forLocalModel(named name: String, bytes: Int64?) -> DeviceImpact {
        let total = Double(physicalMemory)
        let size = Double(bytes ?? estimateBytes(for: name))
        let fraction = size / total
        let gigabytes = size / 1_073_741_824

        let severity: Severity
        switch fraction {
        case ..<0.06:  severity = .light
        case ..<0.15:  severity = .moderate
        case ..<0.30:  severity = .heavy
        default:       severity = .excessive
        }

        let percent = Int((fraction * 100).rounded())
        let headline = String(format: "%@ — about %.1f GB, %d%% of this Mac's memory",
                              severity.label, gigabytes, percent)

        let detail: String
        switch severity {
        case .excessive:
            detail = "This will force swapping while it is loaded. Pick a smaller model."
        case .heavy:
            detail = "Noticeable while loaded, especially alongside builds. Unloads after two minutes idle."
        default:
            detail = "Loaded only while answering, then unloaded after two minutes idle."
        }

        return DeviceImpact(severity: severity, headline: headline,
                            detail: detail, memoryFraction: fraction)
    }

    /// Rough sizing from a model name when the server has not reported one.
    /// Assumes 4-bit quantisation, which is what people actually run locally.
    private static func estimateBytes(for name: String) -> Int64 {
        let lower = name.lowercased()
        let billions: Double
        if let range = lower.range(of: #"(\d+(?:\.\d+)?)\s*b"#, options: .regularExpression) {
            billions = Double(lower[range].replacingOccurrences(of: "b", with: "")
                .trimmingCharacters(in: .whitespaces)) ?? 7
        } else {
            billions = 7
        }
        // ~0.6 GB per billion parameters at 4-bit, plus overhead.
        return Int64(billions * 0.6 * 1_073_741_824)
    }
}
