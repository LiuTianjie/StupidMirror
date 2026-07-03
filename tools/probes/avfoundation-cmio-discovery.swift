#!/usr/bin/env swift
import AVFoundation
import CoreMediaIO
import Foundation

struct Options {
    var seconds: Int = 12
}

func parseOptions() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--seconds":
            if let value = iterator.next(), let parsed = Int(value) {
                options.seconds = max(1, parsed)
            }
        case "--help", "-h":
            print("Usage: swift tools/probes/avfoundation-cmio-discovery.swift [--seconds 12]")
            exit(0)
        default:
            break
        }
    }
    return options
}

func allowScreenCaptureDevices() -> OSStatus {
    let element: CMIOObjectPropertyElement
    if #available(macOS 12.0, *) {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    } else {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
    }

    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: element
    )
    var allow: UInt32 = 1
    return CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allow
    )
}

func deviceTypesForDiscovery() -> [AVCaptureDevice.DeviceType] {
    var types: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external
    ]
    if #available(macOS 13.0, *) {
        types.append(.deskViewCamera)
    }
    if #available(macOS 14.0, *) {
        types.append(.continuityCamera)
    }
    return types
}

func printDevice(_ device: AVCaptureDevice, prefix: String = "-") {
    print("\(prefix) \(device.localizedName)")
    print("  uniqueID: \(device.uniqueID)")
    print("  modelID: \(device.modelID)")
    print("  type: \(device.deviceType.rawValue)")
    print("  suspended: \(device.isSuspended)")
    print("  inUseByAnotherApplication: \(device.isInUseByAnotherApplication)")
}

func discoveryDevices(mediaType: AVMediaType?) -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypesForDiscovery(),
        mediaType: mediaType,
        position: .unspecified
    ).devices
}

func warmUpDiscovery() {
    _ = discoveryDevices(mediaType: nil)
    _ = discoveryDevices(mediaType: .video)
    _ = discoveryDevices(mediaType: .muxed)
}

func printDiscoverySnapshot(label: String) {
    print("\n== \(label) ==")
    let mediaTypes: [(String, AVMediaType?)] = [
        ("video", .video),
        ("audio", .audio),
        ("muxed", .muxed),
        ("nil", nil)
    ]
    for (name, mediaType) in mediaTypes {
        let devices = discoveryDevices(mediaType: mediaType)
        print("\nmedia=\(name) count=\(devices.count)")
        devices.forEach { printDevice($0) }
    }
}

let options = parseOptions()

print("== AVFoundation / CoreMediaIO iPhone screen probe ==")
print("seconds: \(options.seconds)")
print("video authorization: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")

let status = allowScreenCaptureDevices()
print("CMIO allowScreenCaptureDevices status: \(status)")

warmUpDiscovery()
printDiscoverySnapshot(label: "Initial discovery warmup")

var seenDeviceIDs = Set<String>()
let notificationCenter = NotificationCenter.default
let connectedObserver = notificationCenter.addObserver(
    forName: AVCaptureDevice.wasConnectedNotification,
    object: nil,
    queue: .main
) { notification in
    guard let device = notification.object as? AVCaptureDevice else { return }
    print("\n== Notification: connected ==")
    printDevice(device)
}
let disconnectedObserver = notificationCenter.addObserver(
    forName: AVCaptureDevice.wasDisconnectedNotification,
    object: nil,
    queue: .main
) { notification in
    guard let device = notification.object as? AVCaptureDevice else { return }
    print("\n== Notification: disconnected ==")
    printDevice(device)
}

for tick in 0..<options.seconds {
    warmUpDiscovery()
    let muxedDevices = discoveryDevices(mediaType: .muxed)
    let videoDevices = discoveryDevices(mediaType: .video)
    print("\ntick=\(tick) muxed=\(muxedDevices.count) video=\(videoDevices.count)")

    for device in muxedDevices + videoDevices where !seenDeviceIDs.contains(device.uniqueID) {
        seenDeviceIDs.insert(device.uniqueID)
        printDevice(device, prefix: "new")
    }

    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
}

printDiscoverySnapshot(label: "Final discovery snapshot")

notificationCenter.removeObserver(connectedObserver)
notificationCenter.removeObserver(disconnectedObserver)
