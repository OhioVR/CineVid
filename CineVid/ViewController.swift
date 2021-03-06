/////////////
//CineVid///
///////////
///
//  MIT License
//
//  Copyright (c) 2015 Scott Yannitell
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

////PURPOSE
// the purpose of this script is to record video while varying the exposure settings on every frame
// the iso and shutter time are both taken into effect
// this will allow me to take bracketed video. At a high enough frame rate 3 or 4 brackets
// can be enfused to create a realtime video of either 15, 24, 30 or 60 fps
// the idea for this script comes from the custom Canon DLSR firmware:
// Magic Lantern -> http://www.magiclantern.fm
// Magic Lantern is limited to the frame rates offered by the best DLSR cameras that Canon makes
// and currently there is only an option for 2 brackets
// but still the results can be very good as seen from this example
// https://www.youtube.com/watch?v=fjtGenTSfX8
//
// 4 brackets can capture even more information than just 2 and we can have a full 24 or 30 fps output


////program flow:
///
/// set capture session, AV inputs, AV data output, camera settings in viewDidLoad()
///
/// StartStopButtonPressed() toggles recording
///
/// startWriting() sets up the assetwriter and begins to record
///
/// the captureOutput() didDropSampleBuffer overload method counts dropped frames
///
/// in the captureOutput() didOutputSampleBuffer overload method AV samples are written and everytime there is a new video frame, isoSwappomatic is fired
///
/// when the record button is pressed a second time the file is saved and transfered to the camera roll
///
/// pressing the home button will exit the application according to the property set in the plist


////problem #1
//I'm using a video spooler counter because the first few frames are dropped and there is always a short jolt at the beginning which gives the file an incorrect fps
//search for reference $%^& to find this implimentation in this file
//
//my current solution works fine but I believe there is a level of understanding I am lacking to do this properly (without a spool up counter)

////problem #2
//although dropped frames are rare, often times the isoswapper fails to swap the iso in time for the next frame
//you can tell it is failing to swap every frame because at 60 fps and 2 brackets there are irregular surges or dimming in brightness
//ideally I should be able to have at least 4 brackets at 120 fps for an output frame rate of 30 fps.
//This would give me a dynamic range of 14 stops
//in super extreme cases
//you could in theory have 8 bracketed shots at 240 fps for a dynamic range of upto 22 stops
//It remains to be seen that it would be benificial even if it worked due to the limited maximum exposure

////problem #3
// proper focus and exposure settings

////notes
//I think I maybe using the dispatch queue incorrectly. Perhaps there is a way to prioritize or branch off execution
//some people say to use a serial queue for the sample delegates others say to use a global queue. Results seemed to be the same
//
//my knowledge of the grand central dispatch is limited
//
//I measured the time taken to execute isoSwapper using CACurrentMediaTime() and found it vary a lot from less than a milisecond to a little over 8 ms in bursts.

////table of maximum execution time values for the following frame rates:
//
// 30  : 33.37 ms
// 60  : 16.67 ms
// 72  : 13.89 ms
// 90  : 11.11 ms
// 96  : 10.42 ms
// 120 :  8.33 ms
// 240 :  4.17 ms


import UIKit
import AVFoundation
import AssetsLibrary

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    ////AVFOUNDATION OBJECTS
    var PreviewLayer : AVCaptureVideoPreviewLayer!
    var CaptureSession = AVCaptureSession()
    var captureDevice: AVCaptureDevice!
    var videoWriter: AVAssetWriter!
    var videoDataOutput: AVCaptureVideoDataOutput!
    var audioDataOutput: AVCaptureAudioDataOutput!
    var assetWriterAudioInput: AVAssetWriterInput!
    var assetWriterVideoInput: AVAssetWriterInput!
    
    ////VIDEO SETTINGS
    var fileType = AVFileTypeQuickTimeMovie
    var videoOutputSettings = [AVVideoCodecKey: AVVideoCodecH264, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 7000000, AVVideoMaxKeyFrameIntervalKey: 1],
        AVVideoWidthKey: 1280, AVVideoHeightKey: 720] //yes the bit rate is monsterous // keyframe interval of 1 is needed because the frame blinks
    
    ////OUR NESSISARY QUEUES
    var sessionQueue: dispatch_queue_t!
    
    ////TEMPFILE LOCATION
    var outputURL = NSURL()
    var outputPath = ""
    
    ///VITAL CAMERA INFORMATION
    var bracketMax = 2
    var currentBracket = 1
    var durationDenominator = 1 //INCREASING THIS NUMBER MAKES THE SHUTTER FASTER
    var fps: Int32 = 60 //desired frame rate times your number of brackets
    var framerate: CMTime!
    
    var bracketDimISO:Float!
    var bracketBrightISO:Float!
    
    var bracketDimFrameDuration:CMTime!
    var bracketBrightFrameDuration:CMTime!
    
    
    ////WE GET A LOT OF DROPPED FRAMES AT THE BEGINNING
    ///SO IT WON'T RECORD UNTIL ITS SPOOLED UP
    var videoSpoolerUpper = 0
    var videoSpoolerUpperTO = 60
    
    ////PROGRAM STATE
    var WeAreRecording = false // WeAreRecording and isWriting appear to be redundant but there are subtilties
    var isWriting = false
    var firstSample = false
    var flippingISO = false //stop flipping iso when done recording so the program doesn't freeze on app switching
    var droppedFrameCounter = 0
    var isoGlitchGremlin = 0
   // var isoRampState = true
    
    ///remove duplicate frames
    var lastPixelBuffer: CVPixelBuffer!
    
    ////INTERFACE
    @IBOutlet var recordButton: UIButton!
    
    @IBOutlet var dimBracketButton: UIButton!
    
    @IBOutlet var brightBracketButton: UIButton!
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        ////MAKE OUR NESSISARY QUEUES
        sessionQueue = dispatch_queue_create("VideoQueue", DISPATCH_QUEUE_SERIAL)
        
        ////INITIALIZE CAPTURE DEVICE
        captureDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        
        ////ADD VIDEO INPUT
        var error = NSErrorPointer()
        var VideoInputDevice: AVCaptureDeviceInput!
        do {
            VideoInputDevice = try AVCaptureDeviceInput(device: captureDevice!)
        } catch _ as NSError {
            //error.memory = error1
            VideoInputDevice = nil
        }
        if CaptureSession.canAddInput(VideoInputDevice) {
            CaptureSession.addInput(VideoInputDevice)
        } else {
            print("cannot add video input")
        }
        
        ////ADD AUDIO INPUT
        let audioCaptureDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeAudio)
        error = NSErrorPointer()
        var audioInput: AVCaptureDeviceInput!
        do {
            audioInput = try AVCaptureDeviceInput(device: audioCaptureDevice)
        } catch let error1 as NSError {
            error.memory = error1
            audioInput = nil
        }
        if CaptureSession.canAddInput(audioInput) {
            CaptureSession.addInput(audioInput)
        } else {
            print("cannot add audio input")
        }
        
        ////ADD VIDEO PREVIEW LAYER
        ////PreviewLayer = AVCaptureVideoPreviewLayer(layer: CaptureSession) as AVCaptureVideoPreviewLayer
        let PreviewLayer = AVCaptureVideoPreviewLayer(session: CaptureSession)
        
        PreviewLayer!.connection?.videoOrientation = AVCaptureVideoOrientation.LandscapeRight
        
        ////DISPLAY THE PREVIEW LAYER
        ///Display it full screen under out view controller existing controls
        let layerRect = view.bounds
        PreviewLayer.bounds = layerRect
        PreviewLayer.position = CGPointMake(CGRectGetMidX(layerRect), CGRectGetMidY(layerRect))
        let CameraView = UIView()
        view.addSubview(CameraView)
        view.sendSubviewToBack(CameraView) //put the video preview behind the inteface
        CameraView.layer.addSublayer(PreviewLayer)
        
        
        ////ADD VIDEO DATA OUTPUT
        videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.videoSettings = videoDataOutput.recommendedVideoSettingsForAssetWriterWithOutputFileType(fileType)
        if CaptureSession.canAddOutput(videoDataOutput){
            CaptureSession.addOutput(videoDataOutput);
        } else {
            print("cannot add video data output")
        }
        
        ////ADD AUDIO DATA OUTPUT
        audioDataOutput = AVCaptureAudioDataOutput()
        if CaptureSession.canAddOutput(audioDataOutput) {
            CaptureSession.addOutput(audioDataOutput);
        } else {
            print("cannot add audio data output")
        }
        
        ////START THE CAPTURE SESSION RUNNING
        dispatch_async(sessionQueue) {
            self.CameraSetOutputProperties()
            self.CaptureSession.startRunning()
            do {
                try self.captureDevice.lockForConfiguration()
                print("set autofocus")
                self.captureDevice.focusMode = AVCaptureFocusMode.AutoFocus
            } catch _ {
            }
        }
        
        //BEGIN SENDING SAMPLES TO THE captureOutput() OVERLOAD METHODS
        videoDataOutput.setSampleBufferDelegate(self, queue : sessionQueue);
        audioDataOutput.setSampleBufferDelegate(self, queue : sessionQueue);
        
        
        //displaylink style swapping
        //let updater = CADisplayLink(target: self, selector: Selector("Update"))
        //updater.frameInterval = 1
        //updater.addToRunLoop(NSRunLoop.currentRunLoop(), forMode: NSRunLoopCommonModes)
    }
    
    override func viewWillAppear(animated: Bool) {
        WeAreRecording = false
    }
    
    /*//defunct display link swapper
    func Update() {
        if flippingISO {
            isoGlitchGremlin++
            if isoGlitchGremlin < 3 || isoGlitchGremlin > 30 {
                self.isoSwappOMatic()
            }
        } else {
            do {
                try captureDevice.lockForConfiguration()
                captureDevice.focusMode = AVCaptureFocusMode.AutoFocus
                captureDevice.exposureMode = AVCaptureExposureMode.AutoExpose
            } catch _ {
            }
        }
    }
    */
    
    func CameraSetOutputProperties()
    {
        ////at 1080p you will want to look for frames.maxFrameRate to be 60
        ////of course your max frame rate will be only 60 fps
        ////at 720p your frame rate options go as high as 240
        framerate = CMTimeMake(1, fps)
        let CaptureConnection = videoDataOutput.connectionWithMediaType(AVMediaTypeVideo)
        CaptureConnection.videoOrientation = AVCaptureVideoOrientation.LandscapeRight
        for vFormat in captureDevice.formats {
            print(vFormat.formatDescription)
            //var thing = CMVideoFormatDescriptionRef(vFormat.formatDescription);
            //println("\(thing)")
            print(_stdlib_getDemangledTypeName(vFormat.formatDescription))
            var ranges = vFormat.videoSupportedFrameRateRanges as! [AVFrameRateRange]
            let frameRates = ranges[0]
            if frameRates.maxFrameRate == 240 {
                print("ok frame rate here \(vFormat)")
                do {
                    try captureDevice.lockForConfiguration()
                } catch _ {
                }
                captureDevice.activeFormat = vFormat as! AVCaptureDeviceFormat
                captureDevice.activeVideoMinFrameDuration = framerate
                captureDevice.activeVideoMaxFrameDuration = framerate
                captureDevice.unlockForConfiguration()
                print(framerate.timescale)
                break
            }
        }
        
        ////SET THE STABLIZATION MODE
        CaptureConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationMode.Auto
        
        do {
            try captureDevice.lockForConfiguration()
            print("set autofocus")
            captureDevice.focusMode = AVCaptureFocusMode.AutoFocus
        } catch _ {
        } 
    }
    
    
    func captureOutput(captureOutput: AVCaptureOutput!,
        didDropSampleBuffer sampleBuffer: CMSampleBuffer!,
        fromConnection connection: AVCaptureConnection!) {
            droppedFrameCounter++
            print("frame dropped \(droppedFrameCounter)")
    }
    
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!,
        fromConnection connection: AVCaptureConnection!) {
            
            if (self.isWriting == false) {
                return;
            }
            
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let mediaType = CMFormatDescriptionGetMediaType(formatDesc!)
            if mediaType.hashValue == Int(kCMMediaType_Video) {
                videoSpoolerUpper++
                if flippingISO {
                    self.isoSwappOMatic()
                }
                
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                
                if (self.firstSample) {
                    if videoWriter.startWriting() {
                    } else {
                        print("Failed to start writing. \(videoWriter.error)" );
                    }
                    self.firstSample = false;
                }
                
                //$%^&
                if videoSpoolerUpper == videoSpoolerUpperTO {
                    videoWriter.startSessionAtSourceTime(timestamp);
                }
                let pixelBuffer : CVPixelBuffer? = CMSampleBufferGetImageBuffer(sampleBuffer)
                
                if self.assetWriterVideoInput.readyForMoreMediaData && videoSpoolerUpper >= videoSpoolerUpperTO {
                    print("\(pixelBuffer === lastPixelBuffer)")
                    assetWriterVideoInput.appendSampleBuffer(sampleBuffer);
                    lastPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                    
                } else {
                    print("not ready \(videoSpoolerUpper)")
                }
            } else if self.firstSample == false && mediaType.hashValue == Int(kCMMediaType_Audio) && videoSpoolerUpper >= videoSpoolerUpperTO {
                if self.assetWriterAudioInput.readyForMoreMediaData {
                    if self.assetWriterAudioInput.appendSampleBuffer(sampleBuffer) {
                    } else {
                        print("failed to write audio sample")
                    }
                }
            }
    }
    
    func isoSwappOMatic () {
        
        let minISO = self.captureDevice.activeFormat.minISO;
        let maxISO = self.captureDevice.activeFormat.maxISO;
        ////println("minISO \(minISO) maxISO \(maxISO)")
        ///iPhone 6 Plus
        ///minISO 29.0 maxISO 928.0
        
        
        let q =  bracketDimISO - bracketBrightISO
        let leng = q + bracketDimISO;
        let segment = leng / Float(bracketMax);
        var isoVal = segment * Float(currentBracket)
        
        if isoVal < minISO {
            isoVal = minISO
        }
        
        if isoVal > maxISO {
            isoVal = maxISO
        }
        
        let t = bracketDimFrameDuration.value - bracketBrightFrameDuration.value
        let tLeng = t + bracketBrightFrameDuration.value
        let segmentT = tLeng / Int64(bracketMax);
        let timeDurationVal = segmentT * Int64(currentBracket)
        
        let frameTime = CMTimeMake(timeDurationVal, bracketBrightFrameDuration.timescale)

        do {
            try captureDevice.lockForConfiguration()

            captureDevice.setExposureModeCustomWithDuration(frameTime, ISO: isoVal, completionHandler: { (time) -> Void in
                
            })
            
        } catch _ {
        }
        self.captureDevice.unlockForConfiguration()
        currentBracket++;
        if currentBracket > bracketMax  {
            currentBracket = 1;
        }
    }
    
    override func viewDidDisappear(animated: Bool) {
        
        ///normally we would save the current file
        //but doing so crashes the app on app switch back
        //so instead I'm just going to kill my app on switch
        
    }
    
    ////START STOP RECORDING BUTTON
    @IBAction func StartStopButtonPressed(sender : UIButton) {
        if (!WeAreRecording)
        {
            print("START RECORDING")
            WeAreRecording = true
            recordButton.setTitle("stop", forState: UIControlState.Normal)
            
            ////SET OUTPUT URL AND PATH. DELETE ANY FILE THAT EXISTS THERE
            let tmpdir = NSTemporaryDirectory()
            outputPath = "\(tmpdir)output.mov"
            outputURL = NSURL(fileURLWithPath:outputPath as String)
            let filemgr = NSFileManager.defaultManager()
            if filemgr.fileExistsAtPath(outputPath) {
                do {
                    try filemgr.removeItemAtPath(outputPath)
                } catch _ {
                }
            }
            
            ////FREEEZE THE WHITE BALLENCE
            //I'm blocking this out for now
            /*if captureDevice.lockForConfiguration(nil) {
            var gains: AVCaptureWhiteBalanceGains = AVCaptureWhiteBalanceGainsCurrent
            captureDevice.setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains(gains, completionHandler:nil);
            captureDevice.unlockForConfiguration()
            }*/
            flippingISO = true
            
            do {
                try captureDevice.lockForConfiguration()
                captureDevice.focusMode = AVCaptureFocusMode.Locked
            } catch _ {
            }
            
            currentBracket = 1
            startWriting()
        } else {
            do {
                try captureDevice.lockForConfiguration()
                captureDevice.focusMode = AVCaptureFocusMode.AutoFocus
                captureDevice.exposureMode = AVCaptureExposureMode.AutoExpose
            } catch _ {
            }
            stopRecording()
        }
    }
    
    func stopRecording() {
        print("STOP RECORDING")
        recordButton.setTitle("start", forState: UIControlState.Normal)
        WeAreRecording = false
        self.flippingISO = false
        
        ////FINISH WRITING AND TRANSFER RESULTS TO THE CAMERA ROLL
        assetWriterVideoInput.markAsFinished()
        assetWriterAudioInput.markAsFinished()
        self.videoWriter.finishWritingWithCompletionHandler({ () -> Void in
            if self.videoWriter.status == AVAssetWriterStatus.Failed {
                print("VIDEO WRITER ERROR: \(self.videoWriter.error!.description)")
            } else {
                let fileManager = NSFileManager.defaultManager()
                if fileManager.fileExistsAtPath(self.outputPath as String) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
                        if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(self.outputPath) {  ///(fileURL) {
                            //var complete : ALAssetsLibraryWriteVideoCompletionBlock = {reason in print("reason \(reason)")}
                            UISaveVideoAtPathToSavedPhotosAlbum(self.outputPath as String, self, "savingCallBack:didFinishSavingWithError:contextInfo:", nil)
                        } else {
                            print("the file must be bad!")
                        }
                    });
                } else {
                    print("there is no file")
                }
            }
        });
        
        
    }
    
    func savingCallBack(video: NSString, didFinishSavingWithError error:NSError, contextInfo:UnsafeMutablePointer<Void>){
        print("the file has been saved sucessfully")
    }
    
    func startWriting () {
        dispatch_async(sessionQueue, {
            
            ////RESET THE SPOOLER
            self.videoSpoolerUpper = 0
            
            ////CONFIGURE THE ASSET WRITER
            ///Create temporary URL to record to
            let tmpdir = NSTemporaryDirectory()
            self.outputPath = "\(tmpdir)output.mov"
            self.outputURL = NSURL(fileURLWithPath:self.outputPath as String)
            
            ////INITIALIZE ASSET WRITER
            let writeError: NSErrorPointer = nil
            do {
                self.videoWriter = try AVAssetWriter(URL: self.outputURL, fileType: AVFileTypeQuickTimeMovie)
            } catch let error as NSError {
                writeError.memory = error
                self.videoWriter = nil
            } catch {
                fatalError()
            }
            
            ////CONFIGURE VIDEO WRITER
            self.assetWriterVideoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: self.videoOutputSettings as? [String : AnyObject] )
            self.assetWriterVideoInput.expectsMediaDataInRealTime = true
            
            if self.videoWriter.canAddInput(self.assetWriterVideoInput) {
                self.videoWriter.addInput(self.assetWriterVideoInput)
            } else {
                print("unable to add video input to writer")
            }
            
            ////CONFIGURE VIDEO WRITER AUDIO INPUT
            let audioSettings = self.audioDataOutput.recommendedAudioSettingsForAssetWriterWithOutputFileType(self.fileType)
            self.assetWriterAudioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioSettings as? [String: AnyObject])
            self.assetWriterAudioInput.expectsMediaDataInRealTime = true;
            
            if self.videoWriter.canAddInput(self.assetWriterAudioInput) {
                self.videoWriter.addInput(self.assetWriterAudioInput);
            } else {
                print("Unable to add audio input to writer.");
            }
            
            self.isWriting = true;
            self.firstSample = true;
        });
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @IBAction func setBracketBright(sender: AnyObject) {
        bracketBrightISO = captureDevice.ISO
        bracketBrightFrameDuration = captureDevice.exposureDuration
        print("\(bracketBrightISO), \(bracketBrightFrameDuration.timescale) \(bracketBrightFrameDuration.value)")
        brightBracketButton.setTitleColor(UIColor.greenColor(), forState: UIControlState.Normal)
    }
    
    @IBAction func setBracketDim(sender: AnyObject) {
        bracketDimISO = captureDevice.ISO
        bracketDimFrameDuration = captureDevice.exposureDuration
        print("\(bracketDimISO), \(bracketDimFrameDuration.timescale)  \(bracketDimFrameDuration.value)")
        dimBracketButton.setTitleColor(UIColor.greenColor(), forState: UIControlState.Normal)
    }
    
    
}

extension AVCaptureVideoOrientation {
    var uiInterfaceOrientation: UIInterfaceOrientation {
        get {
            switch self {
            case .LandscapeLeft:        return .LandscapeLeft
            case .LandscapeRight:       return .LandscapeRight
            case .Portrait:             return .Portrait
            case .PortraitUpsideDown:   return .PortraitUpsideDown
            }
        }
    }
    
    init(ui:UIInterfaceOrientation) {
        switch ui {
        case .LandscapeRight:       self = .LandscapeRight
        case .LandscapeLeft:        self = .LandscapeLeft
        case .Portrait:             self = .Portrait
        case .PortraitUpsideDown:   self = .PortraitUpsideDown
        default:                    self = .Portrait
        }
    }
}