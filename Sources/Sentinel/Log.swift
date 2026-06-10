import os

enum Log {
    static let subsystem = "com.github.martintreurnicht.sentinel"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let lock = Logger(subsystem: subsystem, category: "lock")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
