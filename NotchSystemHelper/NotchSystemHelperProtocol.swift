import Foundation

@objc protocol NotchSystemHelperProtocol {
    func currentDisplayBrightness(_ displayID: UInt32, with reply: @escaping (NSNumber?) -> Void)
    func setDisplayBrightness(_ value: Float, displayID: UInt32, with reply: @escaping (Bool) -> Void)
    func currentNowPlaying(with reply: @escaping (Data?) -> Void)
    func sendMediaCommand(_ command: Int, with reply: @escaping (Bool) -> Void)
    func seekMedia(_ seconds: Double, with reply: @escaping (Bool) -> Void)
}
