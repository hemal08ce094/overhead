//
//  Permissions.swift
//  Skylight AR
//
//  Camera + location authorization, observable for SwiftUI via Observation.
//

import SwiftUI
import Observation
import CoreLocation
import AVFoundation

@MainActor
@Observable
final class PermissionsModel: NSObject {
    var location: CLAuthorizationStatus
    var camera: AVAuthorizationStatus

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        location = manager.authorizationStatus
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        super.init()
        manager.delegate = self
        location = manager.authorizationStatus
    }

    var locationGranted: Bool { location == .authorizedWhenInUse || location == .authorizedAlways }
    var locationDenied: Bool { location == .denied || location == .restricted }
    var cameraGranted: Bool { camera == .authorized }
    var cameraDenied: Bool { camera == .denied || camera == .restricted }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
    }

    func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = granted ? .authorized : .denied
    }
}

extension PermissionsModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.location = status }
    }
}
