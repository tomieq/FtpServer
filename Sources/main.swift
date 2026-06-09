import Foundation
let server = FtpServerIO()
try server.start(7070, forceIPv4: true)
RunLoop.main.run()
