// Sonda diagnostica: mostra l'indicatore del volume di macOS (OSDManager di OSD.framework) con
// vari parametri di riempimento e cattura lo schermo dopo ognuno. Serve a verificare in CI come il
// servizio di sistema interpreta "filledChiclets/totalChiclets".
import AppKit
import ObjectiveC

typealias ShowImageFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
let sel = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework"), bundle.load(),
      let cls: AnyObject = NSClassFromString("OSDManager"),
      let mgr = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue(),
      let m = class_getInstanceMethod(object_getClass(mgr), sel) else { print("OSDManager non disponibile"); exit(1) }
let show = unsafeBitCast(method_getImplementation(m), to: ShowImageFn.self)
print("firma: \(String(cString: method_getTypeEncoding(m)!))")
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cases: [(String, UInt32, UInt32)] = [("64-di-64", 64, 64), ("32-di-64", 32, 64), ("8-di-16", 8, 16), ("16-di-16", 16, 16), ("50-di-100", 50, 100), ("100-di-100", 100, 100)]
for (name, filled, total) in cases {
    show(mgr, sel, 3, CGMainDisplayID(), 0x1F4, 1500, filled, total, false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "\(out)/osd-\(name).png"]
    try? p.run(); p.waitUntilExit()
    print("catturato \(name)")
    RunLoop.main.run(until: Date().addingTimeInterval(1.8))
}
