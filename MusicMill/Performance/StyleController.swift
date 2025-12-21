import Foundation
import Combine

/// Manages style/genre selection and filtering
class StyleController: ObservableObject {
    @Published var selectedStyle: String?
    @Published var availableStyles: [String] = []
    @Published var styleIntensity: Double = 0.5 // 0.0 to 1.0
    
    /// Updates available styles from model or training data
    func updateStyles(from labels: [String]) {
        availableStyles = labels.sorted()
    }
    
    /// Selects a style
    func selectStyle(_ style: String?) {
        selectedStyle = style
    }
    
    /// Sets style intensity (how strongly to apply the style filter)
    func setIntensity(_ intensity: Double) {
        styleIntensity = max(0.0, min(1.0, intensity))
    }
}


