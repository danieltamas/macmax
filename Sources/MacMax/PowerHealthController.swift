import Foundation
import MacMaxCore

extension ActionController {
    static let powerReadStuckAfter: TimeInterval = 20

    /// Off the main actor: the sensor read walks every SMC key. One read at a time, so a slow one is never overtaken
    /// by a newer one and then overwritten by its older result. A read stuck longer than `powerReadStuckAfter` (the sensor call
    /// hung across sleep) is abandoned, or the card would show the readings from before the sleep for good.
    func readPower() {
        let started = Date()
        if let since = model.readingPowerSince, started.timeIntervalSince(since) < Self.powerReadStuckAfter { return }
        model.readingPowerSince = started
        Task {
            let (battery, status, sensors) = await Task.detached(priority: .utility) {
                (PowerHealthReader.batteryHealth(), PowerHealthReader.batteryStatus(), PowerHealthReader.thermalSensors())
            }.value
            guard model.readingPowerSince == started else { return }
            model.batteryHealth = battery
            model.batteryStatus = status
            model.thermalSensors = sensors
            model.readingPowerSince = nil
        }
    }
}
