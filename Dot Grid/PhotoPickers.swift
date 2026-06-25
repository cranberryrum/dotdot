//
//  PhotoPickers.swift
//  Dot Grid
//
//  Thin SwiftUI wrappers around PHPicker (gallery, no library permission) and
//  UIImagePickerController (camera, needs camera permission).
//

import PhotosUI
import SwiftUI
import UIKit

/// Gallery picker. Uses PHPicker, so it needs no photo-library permission.
///
/// Dismissal is driven by the caller's binding via `onComplete` (nil = cancelled),
/// NOT by `@Environment(\.dismiss)`. The coordinator captures a snapshot of this
/// struct at creation, and a captured dismiss action goes stale — calling it is a
/// no-op, so the presenting sheet's binding never resets and SwiftUI leaves an
/// invisible presentation layer that eats every touch on the screen behind it.
struct GalleryPicker: UIViewControllerRepresentable {
    var onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: GalleryPicker
        init(_ parent: GalleryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onComplete(nil)   // cancelled or nothing usable → still dismiss
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.parent.onComplete(object as? UIImage) }
            }
        }
    }
}

/// Camera capture. Requires camera permission; only present when available.
///
/// Like `GalleryPicker`, dismissal is driven by the caller's binding via
/// `onComplete` (nil = cancelled), not by the coordinator's stale captured
/// `@Environment(\.dismiss)`.
struct CameraPicker: UIViewControllerRepresentable {
    var onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onComplete(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onComplete(nil)
        }
    }

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}
