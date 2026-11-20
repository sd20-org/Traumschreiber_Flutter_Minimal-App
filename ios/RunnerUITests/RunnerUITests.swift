import XCTest

/// B-068: Mit einem echten Traumschreiber verbinden, aufnehmen, 120 s in den Hintergrund,
/// prüfen, dass weiter Daten ankommen. Läuft nur auf einem echten iPhone mit Gerät daneben.
///
///   xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
///     -destination 'id=<UDID>' -only-testing:RunnerUITests -allowProvisioningUpdates
final class RunnerUITests: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    /// Dauerlauf im Demo-Modus (Simulator genügt): Demo starten, Reiter Sleep öffnen und
    /// SOAK_SECONDS (Standard 360) laufen lassen. Den Speicher misst man von außen
    /// (`ps -o rss= -p <pid>`), so findet man Lecks im Schlafmodell ohne Gerät.
    func testDemoSoak() throws {
        app.launch()
        let demo = element("Try the demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "Demo-Knopf fehlt")
        sleep(3)
        demo.tap()
        let sleepTab = element("Sleep")
        if sleepTab.waitForExistence(timeout: 10) { sleepTab.tap() }
        let secs = UInt32(ProcessInfo.processInfo.environment["SOAK_SECONDS"] ?? "") ?? 360
        print("B068 SOAK start \(secs) s")
        sleep(secs)
        shot("soak_end")
        XCTAssertTrue(app.state == .runningForeground, "App läuft nicht mehr")
    }

    /// Bestätigt Systemfenster (Bluetooth, Mitteilungen), falls eines offen ist.
    private func allowSystemAlerts() {
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            for title in ["Allow", "OK", "Erlauben", "Zulassen"] {
                let b = alert.buttons[title]
                if b.exists { b.tap(); break }
            }
        }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Flutter legt Schlüssel und Wert einer Zeile als zwei Texte nebeneinander an.
    /// Je nach Semantik-Baum steht der Wert im selben Label ("Samples received\n12345")
    /// oder im nächsten Element.
    private func samplesReceived() -> Int? {
        let all = app.descendants(matching: .any).allElementsBoundByIndex.map { $0.label }
        guard let i = all.firstIndex(where: { $0.contains("Samples received") }) else { return nil }
        func firstInt(_ s: String) -> Int? {
            Int(s.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty }) ?? "")
        }
        let rest = all[i].components(separatedBy: "Samples received").last ?? ""
        if let n = firstInt(rest) { return n }
        for l in all[(i + 1)...].prefix(3) { if let n = Int(l.trimmingCharacters(in: .whitespacesAndNewlines)) { return n } }
        return nil
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    func testRecordInBackground() throws {
        addUIInterruptionMonitor(withDescription: "System") { alert in
            for title in ["Allow", "OK", "Erlauben", "Zulassen"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        app.launch()
        allowSystemAlerts()

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "Knopf Connect fehlt")
        sleep(3) // Flutter braucht nach dem Start einen Moment, bis Taps ankommen
        let idle = element("Not connected")
        for attempt in 1...3 {
            connect.tap()
            allowSystemAlerts()
            sleep(5)
            if !idle.exists { break }
            print("B068 Connect-Tap \(attempt) ohne Wirkung")
            shot("0_connect_no_effect_\(attempt)")
        }

        let streaming = element("Streaming")
        let ok = streaming.waitForExistence(timeout: 40)
        XCTAssertTrue(ok, "Nach 40 s kein Streaming")
        shot("1_streaming")

        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        sleep(3)
        let before = try XCTUnwrap(samplesReceived(), "Samples received nicht lesbar")
        let tBefore = Date()
        shot("2_recording_before_\(before)")

        XCUIDevice.shared.press(.home)
        sleep(120)
        app.activate()
        sleep(3)

        let after = try XCTUnwrap(samplesReceived(), "Samples received nach Hintergrund nicht lesbar")
        let dt = Date().timeIntervalSince(tBefore)
        shot("3_after_background_\(after)")
        print("B068 samples before=\(before) after=\(after) delta=\(after - before) seconds=\(Int(dt))")
        XCTAssertTrue(element("Streaming").exists, "Nach dem Hintergrund nicht mehr Streaming")
        XCTAssertGreaterThanOrEqual(after - before, 25_000, "Im Hintergrund zu wenig Daten")

        // Stop: der Knopf trägt die Laufzeit hh:mm:ss
        let stop = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*\\d\\d:\\d\\d:\\d\\d.*")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop-Knopf fehlt")
        stop.tap()
        sleep(10)
        let disconnect = element("Disconnect")
        if disconnect.waitForExistence(timeout: 5) { disconnect.tap() }
        let recordings = element("Recordings")
        if recordings.waitForExistence(timeout: 5) { recordings.tap() }
        sleep(2)
        shot("4_recordings")
    }
}
