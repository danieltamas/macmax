import Foundation

/// Rules that are new in MacMax (docs/RULES.md, New rules); the script has no counterpart.
enum NewRules {
    static let brewUnderRosetta = Rule(
        id: "brew_under_rosetta", title: "Homebrew runs under Rosetta", thresholds: [],
        why: "Every brew tool runs translated and slower; native installs are skipped.",
        action: "Install native Homebrew in /opt/homebrew", scriptPattern: nil
    ) { snapshot, _ in
        requiring(snapshot.appleSilicon) { appleSilicon in
            guard appleSilicon else { return .notApplicable }
            return requiring(snapshot.brewInstalls) { brew in
                guard brew.intelPrefixIsX86, !brew.nativePrefixPresent else { return .pass }
                return .warn(title: "Homebrew is the Intel install and runs under Rosetta",
                             evidence: [EvidenceItem("intel_prefix", "/usr/local, x86_64"), EvidenceItem("native_prefix", "absent")])
            }
        }
    }

    static let translatedHot = Rule(
        id: "translated_hot", title: "Busy process under Rosetta",
        thresholds: [Threshold(key: "T_TRANSLATED_CPU", defaultValue: 10, unit: "% CPU", range: 1...1000)],
        why: "Translated code costs extra CPU and battery.", action: nil, scriptPattern: nil
    ) { snapshot, thresholds in
        requiring(snapshot.translatedProcesses) { processes in
            let line = thresholds["T_TRANSLATED_CPU"]
            let hot = processes.filter { $0.cpuSamples.count >= 3 && $0.cpuSamples.suffix(3).allSatisfy { $0 > line } }
                .map { (name: "\($0.name) (\($0.app))", value: $0.cpuSamples.last ?? 0) }
            guard !hot.isEmpty else { return .pass }
            return .warn(title: "\(hot.count) process(es) under Rosetta above \(String(format: "%.0f", line))% CPU",
                         evidence: [EvidenceItem("threshold", String(format: "%.1f", line))]
                            + sortedEvidence(hot) { String(format: "%.1f", $0) })
        }
    }

    static let vpnLeak = Rule(
        id: "vpn_leak", title: "VPN leak", thresholds: [],
        why: "The VPN says connected but traffic leaves outside it.", action: "Open Network, then reconnect the VPN",
        scriptPattern: nil
    ) { snapshot, _ in
        requiring(snapshot.identity) { identity in
            switch identity.verdict {
            case LeakVerdict.leak.rawValue:
                .crit(title: "The VPN is connected but your traffic leaves outside it",
                      evidence: [EvidenceItem("verdict", "leak")])
            // The collector could not decide: neither safe nor leaking, so the rule cannot say.
            case LeakVerdict.unknown.rawValue: .unknown(reason: "the network identity could not be determined")
            case LeakVerdict.off.rawValue: .notApplicable
            default: .pass
            }
        }
    }

    static let vpnExpectedDown = Rule(
        id: "vpn_expected_down", title: "VPN expected but down", thresholds: [],
        why: "Traffic is not protected.", action: "Open Network", scriptPattern: nil
    ) { snapshot, _ in
        guard snapshot.vpnShouldBeOn else { return .notApplicable }
        return requiring(snapshot.identity) { identity in
            identity.vpnConnected ? .pass
                : .warn(title: "A VPN you marked as should be on is disconnected", evidence: [EvidenceItem("vpn", "disconnected")])
        }
    }

    static let ipChanged = Rule(
        id: "ip_changed", title: "Public IP changed", thresholds: [],
        why: "Tells you when the VPN exit or the network changed.", action: nil, scriptPattern: nil
    ) { snapshot, _ in
        requiring(snapshot.previousIdentity, snapshot.identity) { previous, current in
            guard let address = current.publicIP else { return .unknown(reason: "the current public IP is unknown") }
            guard address != previous.publicIP || current.publicCountry != previous.publicCountry else { return .pass }
            func line(_ address: String, _ country: String?) -> String { "\(address) \(country ?? "-")" }
            return .info(title: "Your public IP or its country changed since the last audit",
                         evidence: [EvidenceItem("previous", line(previous.publicIP, previous.publicCountry)),
                                    EvidenceItem("current", line(address, current.publicCountry))])
        }
    }

    static let memoryGrowth = Rule(
        id: "memory_growth", title: "App memory keeps growing",
        thresholds: [Threshold(key: "T_GROWTH_MB", defaultValue: 1024, unit: "MB", range: 64...65536),
                     Threshold(key: "T_GROWTH_PCT", defaultValue: 50, unit: "%", range: 5...1000),
                     Threshold(key: "T_GROWTH_CPU", defaultValue: 5, unit: "% CPU", range: 0.5...100)],
        why: "An idle app that keeps growing is likely leaking; relaunching frees it.", action: "Quit the app and relaunch it",
        scriptPattern: nil
    ) { snapshot, thresholds in
        requiring(snapshot.appGrowth) { apps in
            let growthBytes = thresholds["T_GROWTH_MB"] * 1_048_576
            let grown = apps.compactMap { app -> (name: String, value: Double)? in
                guard app.footprintOneHourAgoBytes > 0, app.footprintBytes > app.footprintOneHourAgoBytes else { return nil }
                let grew = Double(app.footprintBytes - app.footprintOneHourAgoBytes)
                guard grew > growthBytes, grew * 100 > Double(app.footprintOneHourAgoBytes) * thresholds["T_GROWTH_PCT"],
                      app.cpuPercent < thresholds["T_GROWTH_CPU"] else { return nil }
                return (app.name, grew / 1_048_576)
            }
            guard !grown.isEmpty else { return .pass }
            let line = "\(Int(thresholds["T_GROWTH_MB"])) MB and \(Int(thresholds["T_GROWTH_PCT"]))% in an hour, CPU under \(Int(thresholds["T_GROWTH_CPU"]))%"
            return .warn(title: "\(grown.count) app(s) grew a lot in an hour while idle",
                         evidence: [EvidenceItem("threshold", line)] + sortedEvidence(grown) { "+\(Int($0)) MB" })
        }
    }
}
