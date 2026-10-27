import Darwin

enum DataMeter {
    /// Total bytes received + sent on an interface, from the 64-bit counters
    /// (the 32-bit ones in getifaddrs wrap at 4 GB).
    static func bytes(of name: String) -> UInt64? {
        let index = if_nametoindex(name)
        guard index > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(msg.ifm_index) == index { return msg.ifm_data.ifi_ibytes + msg.ifm_data.ifi_obytes }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
            return nil
        }
    }
}
