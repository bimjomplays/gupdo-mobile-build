import UIKit
import XCTest
@testable import GupDo

/// Checks of the app shell that only the iPhone build can answer: the privacy strings the later features need are in
/// the app's Info.plist, and the Now screen renders (its picture is attached to the run's report as now-screen.png).
final class AppShellTests: XCTestCase {
    func testUsageDescriptionsAreSet() {
        let keys = [
            "NSAlarmKitUsageDescription",
            "NSCameraUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NFCReaderUsageDescription",
            "NSMotionUsageDescription",
        ]
        for key in keys {
            let text = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertFalse((text ?? "").isEmpty, "\(key) is missing from Info.plist")
        }
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "GupDo")
    }

    /// The app is this bundle's test host, so its window already shows the Now screen: wait for it, then take its picture.
    @MainActor
    func testNowScreenShows() throws {
        var window: UIWindow?
        let deadline = Date().addingTimeInterval(20)
        while window == nil, Date() < deadline {
            window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let shown = try XCTUnwrap(window, "the app opened no window")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let image = UIGraphicsImageRenderer(bounds: shown.bounds).image { _ in
            _ = shown.drawHierarchy(in: shown.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        let shot = XCTAttachment(image: image)
        shot.name = "now-screen"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
