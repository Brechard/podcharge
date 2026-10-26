import Darwin

private func report(_ message: String) {
    fputs("NetworkSandboxProbe: \(message)\n", stderr)
}

var descriptor = socket(AF_INET, SOCK_STREAM, 0)
if descriptor == -1 {
    let code = errno
    if code == EPERM {
        report("PASS: socket creation denied with EPERM")
        exit(0)
    }
    report("FAIL: socket creation returned errno \(code), expected EPERM")
    exit(1)
}
defer { close(descriptor) }

var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = in_port_t(9).bigEndian
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

if result == 0 {
    report("FAIL: loopback connection unexpectedly succeeded")
    exit(1)
}

let code = errno
if code == EPERM {
    report("PASS: loopback connection denied with EPERM")
    exit(0)
}

report("FAIL: loopback connection returned errno \(code), expected EPERM")
exit(1)
