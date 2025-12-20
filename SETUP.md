# MusicMill Setup Guide

## Creating the Xcode Project

Since this project uses SwiftUI and macOS-specific frameworks, you'll need to create an Xcode project:

1. Open Xcode
2. Select "Create a new Xcode project"
3. Choose "macOS" → "App"
4. Set the following:
   - Product Name: `MusicMill`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Use Core Data: `No`
   - Include Tests: `Yes` (optional)
5. Save the project in the `MusicMill` directory (same level as this file)

## Adding Source Files

After creating the project, add all the source files from the `MusicMill/MusicMill/` directory to your Xcode project:

1. In Xcode, right-click on the project navigator
2. Select "Add Files to MusicMill..."
3. Navigate to the `MusicMill/MusicMill/` directory
4. Select all subdirectories (App, Analysis, ML, Performance, Audio, Training)
5. Make sure "Create groups" is selected (not "Create folder references")
6. Click "Add"

## Project Settings

Configure the following in your Xcode project:

### Build Settings
- **Deployment Target**: macOS 13.0 or later
- **Swift Language Version**: Swift 5.9

### Frameworks
The following frameworks are automatically linked:
- AVFoundation
- CreateML
- CoreML
- Accelerate
- Combine
- SwiftUI

### Capabilities
No special capabilities are required for basic functionality.

## Important Notes

### MLSoundClassifier API
The `ModelTrainer.swift` file contains a template implementation for MLSoundClassifier. You may need to adjust it based on the actual CreateML API. Refer to:
- https://developer.apple.com/documentation/CreateML/MLSoundClassifier

### Testing
Before running:
1. Ensure you have a music collection directory with audio files organized by style/genre (folders = labels)
2. The app will request directory access when you select a music collection

## Running the App

1. Build the project (⌘B)
2. Run the app (⌘R)
3. Navigate to the "Training" tab
4. Select your music collection directory
5. Click "Analyze Collection" to prepare training data
6. Train a model
7. Switch to the "Performance" tab to use the live interface

## Troubleshooting

### Build Errors
- Ensure all files are added to the Xcode project target
- Check that deployment target is set to macOS 13.0+
- Verify all imports are correct

### Runtime Issues
- Check console for error messages
- Ensure audio files are in supported formats (MP3, AAC, WAV, AIFF)
- Verify directory permissions for music collection access

