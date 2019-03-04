/**
 * Copyright IBM Corporation 2017, 2018
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import UIKit
import AVFoundation

import VisualRecognitionV3

class CameraViewController: UIViewController {

    // MARK: - IBOutlets
    
    @IBOutlet weak var cameraView: UIView!
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var heatmapView: UIImageView!
    @IBOutlet weak var outlineView: UIImageView!
    @IBOutlet weak var focusView: UIImageView!
    @IBOutlet weak var simulatorTextView: UITextView!
    @IBOutlet weak var captureButton: UIButton!
    @IBOutlet weak var updateModelButton: UIButton!
    @IBOutlet weak var choosePhotoButton: UIButton!
    @IBOutlet weak var closeButton: UIButton!
    @IBOutlet weak var alphaSlider: UISlider!
    @IBOutlet weak var pickerView: AKPickerView!
    
    // MARK: - Variable Declarations
    
    let visualRecognition: VisualRecognition = {
        guard let path = Bundle.main.path(forResource: "Credentials", ofType: "plist") else {
            // Please create a Credentials.plist file with your Visual Recognition credentials.
            fatalError()
        }
        guard let apiKey = NSDictionary(contentsOfFile: path)?["apiKey"] as? String else {
            // No Visual Recognition API key found. Make sure you add your API key to the Credentials.plist file.
            fatalError()
        }
        return VisualRecognition(version: VisualRecognitionConstants.version, apiKey: apiKey)
    }()
    
    let photoOutput = AVCapturePhotoOutput()
    lazy var captureSession: AVCaptureSession? = {
        guard let backCamera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: backCamera) else {
                return nil
        }
        
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        captureSession.addInput(input)
        
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.frame = CGRect(x: view.bounds.minX, y: view.bounds.minY, width: view.bounds.width, height: view.bounds.height)
            // `.resize` allows the camera to fill the screen on the iPhone X.
            previewLayer.videoGravity = .resize
            previewLayer.connection?.videoOrientation = .portrait
            cameraView.layer.addSublayer(previewLayer)
            return captureSession
        }
        return nil
    }()
    
    let defaultClassifiers = ["default", "explicit", "food"]
    
    var editedImage = UIImage()
    var originalConfs = [ClassResult]()
    var heatmaps = [String: HeatmapImages]()
    var selectionIndex = 0
    var classifiers = [String]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        captureSession?.startRunning()
        resetUI()
        
        pickerView.delegate = self
        pickerView.dataSource = self
        pickerView.interitemSpacing = CGFloat(25.0)
        pickerView.pickerViewStyle = .flat
        pickerView.maskDisabled = true
        pickerView.font = UIFont.boldSystemFont(ofSize: 14)
        pickerView.highlightedFont = UIFont.boldSystemFont(ofSize: 14)
        pickerView.highlightedTextColor = UIColor.white
        pickerView.textColor = UIColor(red: 1, green: 1, blue: 1, alpha: 0.6)
        if let lastClassifier = UserDefaults.standard.string(forKey: "classifier_id") {
            classifiers.append(lastClassifier)
        }
        pickerView.reloadData()
        
        var modelList = [String]()
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        visualRecognition.listClassifiers() { response, error in
            defer { dispatchGroup.leave() }
            guard let classifiers = response?.result?.classifiers else {
                return
            }
            for classifier in classifiers {
                modelList.append(classifier.classifierID)
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            self.classifiers = modelList
            self.pickerView.reloadData()
            self.pickerView.selectItem(self.selectionIndex)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let drawer = pulleyViewController?.drawerContentViewController as? ResultsTableViewController else {
            return
        }
        drawer.delegate = self
    }
    
    // MARK: - Image Classification
    
    func classifyImage(_ image: UIImage, localThreshold: Double = 0.0) {
        guard let croppedImage = cropToCenter(image: image, targetSize: CGSize(width: 224, height: 224)) else {
            return
        }
        
        editedImage = croppedImage
        
        showResultsUI(for: image)
        
        guard let classifierId = UserDefaults.standard.string(forKey: "classifier_id") else {
            return
        }
        
        do {
            let _ = try visualRecognition.getLocalModel(classifierID: classifierId)
            visualRecognition.classifyWithLocalModel(image: editedImage, classifierIDs: [classifierId], threshold: localThreshold) { classifiedImages, error in
                // Make sure that an image was successfully classified.
                guard let classifications = classifiedImages?.images.first?.classifiers.first?.classes else {
                    return
                }
                
                DispatchQueue.main.async {
                    self.push(results: classifications)
                }
                
                self.originalConfs = classifications
            }
        } catch {
            visualRecognition.classify(image: editedImage, threshold: localThreshold, classifierIDs: [classifierId]) { response, error in
                // Make sure that an image was successfully classified.
                guard let classifications = response?.result?.images.first?.classifiers.first?.classes else {
                    return
                }
                
                DispatchQueue.main.async {
                    self.push(results: classifications)
                }
                
                self.originalConfs = classifications
            }
        }
    }
    
    func startAnalysis(classToAnalyze: String, localThreshold: Double = 0.0) {
        if let heatmapImages = heatmaps[classToAnalyze] {
            heatmapView.image = heatmapImages.heatmap
            outlineView.image = heatmapImages.outline
            return
        }
        
        var confidences = [[Double]](repeating: [Double](repeating: -1, count: 17), count: 17)
        
        DispatchQueue.main.async {
            SwiftSpinner.show("analyzing")
        }
        
        let chosenClasses = originalConfs.filter({ return $0.className == classToAnalyze })
        guard let chosenClass = chosenClasses.first else {
            return
        }
        let originalConf = Double(chosenClass.score)
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        
        DispatchQueue.global(qos: .background).async {
            for down in 0 ..< 11 {
                for right in 0 ..< 11 {
                    confidences[down + 3][right + 3] = 0
                    dispatchGroup.enter()
                    let maskedImage = self.maskImage(image: self.editedImage, at: CGPoint(x: right, y: down))
                    
                    guard let classifierId = UserDefaults.standard.string(forKey: "classifier_id") else {
                        return
                    }
                    self.visualRecognition.classifyWithLocalModel(image: maskedImage, classifierIDs: [classifierId], threshold: localThreshold) { [down, right] classifiedImages, _ in
                        
                        defer { dispatchGroup.leave() }
                        
                        // Make sure that an image was successfully classified.
                        guard let classifications = classifiedImages?.images.first?.classifiers.first?.classes else {
                            return
                        }
                        
                        let usbClass = classifications.filter({ return $0.className == classToAnalyze })
                        
                        guard let usbClassSingle = usbClass.first else {
                                return
                        }
                        
                        let score = Double(usbClassSingle.score)
                        
                        print(".", terminator: "")
                        
                        confidences[down + 3][right + 3] = score
                    }
                }
            }
            dispatchGroup.leave()
            
            dispatchGroup.notify(queue: .main) {
                print()
                print(confidences)
                
                guard let image = self.imageView.image else {
                    return
                }
                
                let heatmap = self.calculateHeatmap(confidences, originalConf)
                let heatmapImage = self.renderHeatmap(heatmap, color: .black, size: image.size)
                let outlineImage = self.renderOutline(heatmap, size: image.size)
                
                let heatmapImages = HeatmapImages(heatmap: heatmapImage, outline: outlineImage)
                self.heatmaps[classToAnalyze] = heatmapImages
                
                self.heatmapView.image = heatmapImage
                self.outlineView.image = outlineImage
                self.heatmapView.alpha = CGFloat(self.alphaSlider.value)
                
                self.heatmapView.isHidden = false
                self.outlineView.isHidden = false
                self.alphaSlider.isHidden = false
                
                SwiftSpinner.hide()
            }
        }
    }
    
    func maskImage(image: UIImage, at point: CGPoint) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        
        image.draw(at: .zero)
        
        let rectangle = CGRect(x: point.x * 16, y: point.y * 16, width: 64, height: 64)
        
        UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
        UIRectFill(rectangle)
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    func cropToCenter(image: UIImage, targetSize: CGSize) -> UIImage? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        
        let offset = abs(CGFloat(cgImage.width - cgImage.height) / 2)
        let newSize = CGFloat(min(cgImage.width, cgImage.height))
        
        let cropRect: CGRect
        if cgImage.width < cgImage.height {
            cropRect = CGRect(x: 0.0, y: offset, width: newSize, height: newSize)
        } else {
            cropRect = CGRect(x: offset, y: 0.0, width: newSize, height: newSize)
        }
        
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }
        
        let image = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        let resizeRect = CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        image.draw(in: resizeRect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        return newImage
    }
    
    func dismissResults() {
        push(results: [], position: .closed)
    }
    
    func push(results: [ClassResult], position: PulleyPosition = .partiallyRevealed) {
        guard let drawer = pulleyViewController?.drawerContentViewController as? ResultsTableViewController else {
            return
        }
        drawer.classifications = results
        pulleyViewController?.setDrawerPosition(position: position, animated: true)
        drawer.tableView.reloadData()
    }
    
    func showResultsUI(for image: UIImage) {
        imageView.image = image
        imageView.isHidden = false
        simulatorTextView.isHidden = true
        closeButton.isHidden = false
        captureButton.isHidden = true
        choosePhotoButton.isHidden = true
        updateModelButton.isHidden = true
        focusView.isHidden = true
    }
    
    func resetUI() {
        heatmaps = [String: HeatmapImages]()
        if captureSession != nil {
            simulatorTextView.isHidden = true
            imageView.isHidden = true
            captureButton.isHidden = false
            focusView.isHidden = false
        } else {
            imageView.image = UIImage(named: "Background")
            simulatorTextView.isHidden = false
            imageView.isHidden = false
            captureButton.isHidden = true
            focusView.isHidden = true
        }
        heatmapView.isHidden = true
        outlineView.isHidden = true
        alphaSlider.isHidden = true
        closeButton.isHidden = true
        choosePhotoButton.isHidden = false
        updateModelButton.isHidden = false
        dismissResults()
    }
    
    // MARK: - IBActions
    
    @IBAction func sliderValueChanged(_ sender: UISlider) {
        let currentValue = CGFloat(sender.value)
        self.heatmapView.alpha = currentValue
    }
    
    @IBAction func checkUpdates() {
        guard let modelId = UserDefaults.standard.string(forKey: "classifier_id") else {
            return
        }
        visualRecognition.checkLocalModelStatus(classifierID: modelId) { modelUpToDate in
            if !modelUpToDate {
                SwiftSpinner.show("Compiling model...")
                self.visualRecognition.updateLocalModel(classifierID: modelId) { response, error in
                    defer {
                        DispatchQueue.main.async {
                            SwiftSpinner.hide()
                            self.updateModelButton.isHidden = true
                        }
                    }
                    
                    guard let error = error else {
                        return
                    }
                    
                    DispatchQueue.main.async {
                        self.modelUpdateFail(modelId: modelId, error: error)
                    }
                }
            }
        }
    }
    
    @IBAction func capturePhoto() {
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
    
    @IBAction func presentPhotoPicker() {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true)
    }
    
    @IBAction func reset() {
        resetUI()
    }
    
    // MARK: - Structs
    
    struct HeatmapImages {
        let heatmap: UIImage
        let outline: UIImage
    }
}

// MARK: - Error Handling

extension CameraViewController {
    func showAlert(_ alertTitle: String, alertMessage: String) {
        let alert = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Dismiss", style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
    
    func modelUpdateFail(modelId: String, error: Error) {
        let error = error as NSError
        var errorMessage = ""
        
        // 0 = probably wrong api key
        // 404 = probably no model
        // -1009 = probably no internet
        
        switch error.code {
        case 0:
            errorMessage = "Please check your Object Storage API key in `Credentials.plist` and try again."
        case 404:
            errorMessage = "We couldn't find a bucket with ID: \"\(modelId)\""
        case 500:
            errorMessage = "Internal server error. Please try again."
        case -1009:
            errorMessage = "Please check your internet connection."
        default:
            errorMessage = "Please try again."
        }
        
        // TODO: Do some more checks, does the model exist? is it still training? etc.
        // The service's response is pretty generic and just guesses.
        
        showAlert("Unable to download model", alertMessage: errorMessage)
    }
}

// MARK: - UIImagePickerControllerDelegate

extension CameraViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        
        guard let image = info[.originalImage] as? UIImage else {
            return
        }
        
        classifyImage(image)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print(error.localizedDescription)
            return
        }
        guard let photoData = photo.fileDataRepresentation(),
            let image = UIImage(data: photoData) else {
            return
        }
        
        classifyImage(image)
    }
}

// MARK: - TableViewControllerSelectionDelegate

extension CameraViewController: TableViewControllerSelectionDelegate {
    func didSelectItem(_ name: String) {
        guard let classifierId = UserDefaults.standard.string(forKey: "classifier_id") else {
            return
        }
        do {
            let _ = try visualRecognition.getLocalModel(classifierID: classifierId)
            startAnalysis(classToAnalyze: name)
        } catch {
            return
        }
    }
}

// MARK: - AKPickerViewDataSource

extension CameraViewController: AKPickerViewDataSource {
    func numberOfItemsInPickerView(_ pickerView: AKPickerView) -> Int {
        return defaultClassifiers.count + max(classifiers.count, 1)
    }
    
    func pickerView(_ pickerView: AKPickerView, titleForItem item: Int) -> String {
        if item < defaultClassifiers.count {
            if defaultClassifiers[item] == UserDefaults.standard.string(forKey: "classifier_id") {
                selectionIndex = item
            }
            return defaultClassifiers[item]
        }
        if classifiers.count <= 0 {
            return "Loading..."
        }
        
        let scaledItem = item - defaultClassifiers.count
        
        if classifiers[scaledItem] == UserDefaults.standard.string(forKey: "classifier_id") {
            selectionIndex = item
        }
        return classifiers[scaledItem]
    }
}

// MARK: - AKPickerViewDelegate

extension CameraViewController: AKPickerViewDelegate {
    func pickerView(_ pickerView: AKPickerView, didSelectItem item: Int) {
        updateModelButton.isEnabled = false
        choosePhotoButton.isEnabled = false
        captureButton.isEnabled = false
        if item < defaultClassifiers.count {
            updateModelButton.isHidden = false
            choosePhotoButton.isEnabled = true
            captureButton.isEnabled = true
            let classifierId = defaultClassifiers[item]
            UserDefaults.standard.set(classifierId, forKey: "classifier_id")
        } else {
            if classifiers.count > 0 {
                choosePhotoButton.isEnabled = true
                captureButton.isEnabled = true
                updateModelButton.isEnabled = true
                let classifierId = classifiers[item - defaultClassifiers.count]
                UserDefaults.standard.set(classifierId, forKey: "classifier_id")
                do {
                    let _ = try visualRecognition.getLocalModel(classifierID: classifierId)
                    updateModelButton.isHidden = true
                } catch {
                    updateModelButton.isHidden = false
                }
            }
        }
    }
}