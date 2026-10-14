# AudioReceiver Setup Guide

This project was generated with a file-first approach. Since the `.xcodeproj` file needs to be created manually, follow these steps:

## 1. Create Project
1. Open Xcode.
2. **File > New > Project**.
3. Select **App**.
4. Product Name: `AudioReceiver`.
5. Interface: **SwiftUI**.
6. Life Cycle: **SwiftUI App**.
7. Language: **Swift**.
8. Save it in this directory: `/Users/chrislapointe/Projects/CurrentProjects/AudioReceiver`.

## 2. Import Files
1. Delete the default `ContentView.swift` and `AudioReceiverApp.swift` created by Xcode.
2. Drag the following folders from Finder into the Xcode Project Navigator:
   - `App`
   - `Models`
   - `Services`
   - `UI`
3. **IMPORTANT**: In the dialog that appears:
   - **Uncheck** "Copy items if needed" (We want to use the files where they are).
   - Select "Create groups".
   - Ensure the "AudioReceiver" target is checked.

## 3. Configure Info.plist
1. I have generated a prepared `Info.plist` in the `App` folder.
2. In Xcode, click on the Project (root icon) > Target (AudioReceiver) > **Build Settings**.
3. Search for **Info.plist File**.
4. Change the path to: `AudioReceiver/App/Info.plist` (or wherever it ended up relative to the xcodeproj). 
   *Alternatively*: Open the default Info.plist Xcode created and manually add:
   - `App Transport Security Settings` -> `Allow Arbitrary Loads` = `YES`
   - `Required background modes` -> item 0 = `App plays audio or streams audio/video using AirPlay`

## 4. Minimum Deployment Target
1. Go to Project > Target > **General** > **Deployment Info**.
2. Set **iOS Deployment Target** to **14.6**.

## 5. Deploy
1. Open Terminal.
2. Run `./deploy.sh`.
