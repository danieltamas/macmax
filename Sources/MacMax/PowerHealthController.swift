import Foundation
import MacMaxCore

extension ActionController {
    /// Off the main actor: the sensor read walks every SMC key. One read at a time, so a slow one is never overtaken
    /// by a newer one and then overwritten by its older result.
    func readPower() {
        guard !model.readingPower else { return }
        model.readingPower = true
        Task {
            let (battery, sensors) = await Task.detached(priority: .utility) { (PowerHealthReader.batteryHealth(), PowerHealthReader.thermalSensors()) }.value
            model.batteryHealth = battery
            model.thermalSensors = sensors
            model.readingPower = false
        }
    }
}
