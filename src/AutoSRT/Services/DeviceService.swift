import Foundation
import IOKit

public class DeviceService {
    public static let shared = DeviceService()
    
    private init() {}
    
    // Get system UUID (hardware UUID)
    public func getSystemUUID() -> String {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        
        guard platformExpert > 0 else {
            return UUID().uuidString // Fallback to random UUID if we can't get system UUID
        }
        
        guard let uuid = (IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String) else {
            return UUID().uuidString
        }
        
        return uuid
    }
    
    // Get system serial number
    public func getSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        
        guard platformExpert > 0 else { return nil }
        
        guard let serialNumber = (IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String) else {
            return nil
        }
        
        return serialNumber
    }
    
    // Get device model identifier
    public func getModelIdentifier() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        
        guard platformExpert > 0 else { return nil }
        
        guard let model = (IORegistryEntryCreateCFProperty(platformExpert, "model" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? Data) else {
            return nil
        }
        
        return String(data: model, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }
    
    // Get macOS version
    public func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    // Get device info dictionary
    public func getDeviceInfo() -> [String: String] {
        var info: [String: String] = [:]
        
        info["uuid"] = getSystemUUID()
        info["os_version"] = getOSVersion()
        
        if let serialNumber = getSerialNumber() {
            info["serial_number"] = serialNumber
        }
        
        if let modelIdentifier = getModelIdentifier() {
            info["model_identifier"] = modelIdentifier
        }
        
        info["hostname"] = Host.current().localizedName ?? "Unknown"
        
        if let systemArchitecture = getSystemArchitecture() {
            info["system_architecture"] = systemArchitecture
        }
        
        return info
    }
    
    // Get system architecture (Intel/Apple Silicon)
    public func getSystemArchitecture() -> String? {
        var size = size_t(0)
        var arch: String?
        
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: Int(size))
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        let machineString = String(cString: machine)
        
        if machineString.contains("Intel") {
            arch = "Intel"
        } else {
            // Check for Apple Silicon
            var ret = utsname()
            uname(&ret)
            let machine = withUnsafePointer(to: ret.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            
            if machine.contains("arm64") {
                arch = "Apple Silicon"
            }
        }
        
        return arch
    }
}
