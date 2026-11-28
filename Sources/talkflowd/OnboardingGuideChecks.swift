import CoreGraphics
import Foundation

// Self-test items 35-41 (app location and guide placement), run from
// `--streamtest`. Pure: no windows, no permissions.

enum OnboardingGuideChecks {
    static func run(_ check: (Bool, String, String) -> Void) {
        // 35. AppLocation.classify
        let locations: [(String, Bool, AppLocation)] = [
            ("/Applications/talkflow.app", false, .fine),
            ("/Users/a/Applications/talkflow.app", false, .fine),
            ("/Volumes/talkflow/talkflow.app", true, .diskImage),
            ("/Volumes/talkflow/talkflow.app/", true, .diskImage),
            ("/private/var/folders/ab/cd/T/AppTranslocation/1F2E-3D4C/d/talkflow.app", true, .translocated),
            ("/Users/a/Documents/talkflow/.build/debug", false, .fine),
            ("/Volumes/External/Apps/talkflow.app", false, .fine),
            ("/Users/a/Downloads/talkflow.app", false, .fine),
            ("/Volumes/talkflow/.build/debug", true, .fine),
        ]
        for (path, readOnly, want) in locations {
            let got = AppLocation.classify(bundlePath: path, onReadOnlyVolume: readOnly)
            check(got == want, "location: \(path) ro=\(readOnly)", "\(got)")
        }

        // 36-39. GuidePlacement.origin, screen (0,0,1440,900), panel (280,84)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = CGSize(width: 280, height: 84)
        let placements: [(CGRect, CGPoint)] = [
            (CGRect(x: 300, y: 200, width: 700, height: 500), CGPoint(x: 1012, y: 556)),
            (CGRect(x: 700, y: 200, width: 700, height: 500), CGPoint(x: 408, y: 556)),
            (CGRect(x: 0, y: 100, width: 1440, height: 800), CGPoint(x: 1144, y: 116)),
            (CGRect(x: 300, y: 750, width: 700, height: 500), CGPoint(x: 1012, y: 816)),
        ]
        for (i, (settings, want)) in placements.enumerated() {
            let got = GuidePlacement.origin(settings: settings, screen: screen, panel: panel)
            check(got == want, "guide: placement \(36 + i)", "\(got)")
        }

        // 40. cocoaRect
        let cocoa = GuidePlacement.cocoaRect(cg: CGRect(x: 100, y: 50, width: 700, height: 500), primaryHeight: 900)
        check(cocoa == CGRect(x: 100, y: 350, width: 700, height: 500), "guide: cocoaRect", "\(cocoa)")

        // 41. pickSettingsWindow
        func entry(_ pid: Int, _ layer: Int, _ rect: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer,
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let big = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let infos: [[String: Any]] = [
            entry(7, 0, big),
            entry(42, 25, big),
            entry(42, 0, CGRect(x: 10, y: 10, width: 200, height: 100)),
            entry(42, 0, CGRect(x: 40, y: 60, width: 800, height: 600)),
            entry(42, 0, CGRect(x: 0, y: 0, width: 900, height: 700)),
        ]
        let picked = GuidePlacement.pickSettingsWindow(infos, pid: 42)
        check(picked == CGRect(x: 40, y: 60, width: 800, height: 600), "guide: pickSettingsWindow front-most", "\(String(describing: picked))")
        let none = GuidePlacement.pickSettingsWindow([], pid: 42)
        check(none == nil, "guide: pickSettingsWindow empty", "\(String(describing: none))")
        let wrong = GuidePlacement.pickSettingsWindow([entry(7, 0, big), entry(8, 0, big)], pid: 42)
        check(wrong == nil, "guide: pickSettingsWindow wrong pid", "\(String(describing: wrong))")
    }
}
