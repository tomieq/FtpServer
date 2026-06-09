//
//  Errno.swift
//  ftpServer
//
//  Created by Tomasz on 19/08/2025.
//

import Foundation

public class Errno {

    public class func description() -> String {
        // https://forums.developer.apple.com/thread/113919
        return String(cString: strerror(errno))
    }
}
