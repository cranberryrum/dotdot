//
//  PhotoPickers.swift
//  Dot Grid
//
//  Thin SwiftUI wrapper around PHPicker (gallery, no library permission). The camera
//  is no longer a modal picker — it's the embedded live preview in Camera.swift.
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
