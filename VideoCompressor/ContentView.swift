import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import Photos

// MARK: - Enums
enum ResolutionOption: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    
    var id: String { rawValue }
    var dimensions: CGSize? {
        switch self {
        case .original: return nil
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p720: return CGSize(width: 1280, height: 720)
        case .p480: return CGSize(width: 854, height: 480)
        }
    }
}

enum CodecOption: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    
    var id: String { rawValue }
}

// MARK: - Preset System
enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced"
    case social = "Social Media"
    case archive = "Archive"
    case highQuality = "High Quality"
    case original = "Original"

    var id: String { rawValue }

    var compressionLevel: Double {
        switch self {
        case .balanced:     return 0.5
        case .social:       return 0.3
        case .archive:      return 0.15
        case .highQuality:  return 0.75
        case .original:     return 0.95
        }
    }

    var resolution: ResolutionOption {
        switch self {
        case .balanced:     return .p720
        case .social:       return .p720
        case .archive:      return .p480
        case .highQuality:  return .p1080
        case .original:     return .original
        }
    }

    var codec: CodecOption {
        switch self {
        case .balanced, .social, .highQuality: return .h264
        case .archive, .original:              return .hevc
        }
    }

    var frameRate: Double {
        switch self {
        case .balanced:     return 30
        case .social:       return 30
        case .archive:      return 24
        case .highQuality:  return 30
        case .original:     return 30
        }
    }
}

struct PreviewItem: Identifiable {
    let id = UUID()
    let player: AVPlayer
}

struct ContentView: View {
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?
    @State private var videoDuration: Double = 0
    @State private var originalFileSize: Int64 = 0
    @State private var originalBitrate: Double = 0
    @State private var originalSize: CGSize = .zero
    
    @State private var compressionLevel: Double = 0.5
    @State private var estimatedOutputSize: Int64 = 0
    
    @State private var showAdvanced = false
    @State private var selectedResolution: ResolutionOption = .original
    @State private var selectedCodec: CodecOption = .h264
    @State private var targetFrameRate: Double = 30
    
    @State private var selectedPreset: CompressionPreset? = nil
    @State private var isApplyingPreset = false

    @State private var isCompressing = false
    @State private var compressionProgress: Double = 0
    @State private var compressedVideoURL: URL?
    @State private var compressedFileSize: Int64 = 0
    @State private var showingVideoPicker = false
    @State private var errorMessage: String?
    @State private var showingShareSheet = false
    @State private var previewItem: PreviewItem?
    @State private var saveSuccessMessage: String?
    @State private var didSaveToPhotos = false

    @State private var activeAssetReader: AVAssetReader?
    @State private var activeAssetWriter: AVAssetWriter?
    @State private var activeOutputURL: URL?
    // Identifies the current compression run so a completion callback from an
    // old (cancelled/replaced) run can tell it's stale and avoid clobbering a
    // newer run's UI state.
    @State private var currentRunID: UUID?

    private let minBitrate: Double = 800
    private let maxBitrate: Double = 6000

    var targetBitrate: Double {
        let raw = minBitrate + (maxBitrate - minBitrate) * compressionLevel
        let originalKbps = originalBitrate / 1000
        // Never let the "compressed" bitrate exceed the source's own bitrate —
        // that would grow the file instead of shrinking it. Clamp the final
        // value directly rather than adjusting the slider's ceiling, since the
        // source can be below `minBitrate` too.
        guard originalKbps > 0 else { return raw }
        return min(raw, originalKbps)
    }

    private enum SettingsKey {
        static let compressionLevel = "settings.compressionLevel"
        static let resolution = "settings.resolution"
        static let codec = "settings.codec"
        static let frameRate = "settings.frameRate"
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKey.compressionLevel) != nil {
            compressionLevel = defaults.double(forKey: SettingsKey.compressionLevel)
        }
        if let rawResolution = defaults.string(forKey: SettingsKey.resolution),
           let resolution = ResolutionOption(rawValue: rawResolution) {
            selectedResolution = resolution
        }
        if let rawCodec = defaults.string(forKey: SettingsKey.codec),
           let codec = CodecOption(rawValue: rawCodec) {
            selectedCodec = codec
        }
        if defaults.object(forKey: SettingsKey.frameRate) != nil {
            targetFrameRate = defaults.double(forKey: SettingsKey.frameRate)
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(compressionLevel, forKey: SettingsKey.compressionLevel)
        defaults.set(selectedResolution.rawValue, forKey: SettingsKey.resolution)
        defaults.set(selectedCodec.rawValue, forKey: SettingsKey.codec)
        defaults.set(targetFrameRate, forKey: SettingsKey.frameRate)
    }

    // Hide resolution targets that exceed the source — picking them would
    // upscale rather than compress.
    private var availableResolutions: [ResolutionOption] {
        ResolutionOption.allCases.filter { option in
            guard let dims = option.dimensions else { return true }
            let longEdge = max(originalSize.width, originalSize.height)
            let shortEdge = min(originalSize.width, originalSize.height)
            guard longEdge > 0 else { return true }
            return dims.width <= longEdge && dims.height <= shortEdge
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    videoPreviewSection
                    if selectedVideoURL != nil {
                        videoInfoSection
                        presetsSection
                        compressionLevelSection
                        advancedOptionsSection
                    }
                    if selectedVideoURL != nil && !isCompressing {
                        compressButtonSection
                    }
                    if isCompressing {
                        compressingSection
                    }
                    if let compressedURL = compressedVideoURL {
                        completedSection(compressedURL: compressedURL)
                    }
                    messagesSection
                }
                .padding()
            }
            .onAppear { loadSettings() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { titleToolbar }
            .sheet(isPresented: $showingVideoPicker) {
                VideoPicker(selectedVideoURL: $selectedVideoURL, onVideoSelected: loadVideo)
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = compressedVideoURL { ShareSheet(activityItems: [url]) }
            }
            .fullScreenCover(item: $previewItem) { item in
                FullScreenVideoPlayer(player: item.player) { previewItem = nil }
            }
        }
    }

    @ToolbarContentBuilder
    private var titleToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack.fill")
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Video Compressor")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing)
                    )
            }
        }
    }

    @ViewBuilder
    private var videoPreviewSection: some View {
        if let player = player {
            VideoPlayer(player: player)
                .frame(height: 220)
                .cornerRadius(12)
        } else {
            Button(action: { showingVideoPicker = true }) {
                VStack {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 60))
                    Text("Select Video")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var videoInfoSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Original: \(formatBytes(originalFileSize))")
                if originalBitrate > 0 {
                    Text("Bitrate: \(Int(originalBitrate / 1000)) kbps")
                }
                if originalSize.width > 0 {
                    Text("Resolution: \(Int(originalSize.width)) × \(Int(originalSize.height))")
                }
            }
            Spacer()
            if estimatedOutputSize > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Est. Output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatBytes(estimatedOutputSize))
                        .font(.headline)
                        .foregroundColor(.blue)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Presets")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CompressionPreset.allCases) { preset in
                        Button(action: {
                            applyPreset(preset)
                        }) {
                            Text(preset.rawValue)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(selectedPreset == preset ? Color.blue : Color.gray.opacity(0.15))
                                .foregroundColor(selectedPreset == preset ? .white : .primary)
                                .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var compressionLevelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compression Level: \(Int(compressionLevel * 100))%")
                .font(.headline)
            Text("Target Bitrate: \(Int(targetBitrate)) kbps")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Slider(value: $compressionLevel, in: 0...1, step: 0.01)
                .onChange(of: compressionLevel) { _ in
                    // onChange fires for programmatic writes too (e.g. applyPreset
                    // setting compressionLevel), not just user drags — don't clear
                    // the just-applied preset selection in that case.
                    if !isApplyingPreset {
                        selectedPreset = nil
                    }
                    updateEstimatedSize()
                    saveSettings()
                }

            HStack {
                Text("Low (Smaller)")
                    .font(.caption)
                Spacer()
                Text("High (Better)")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }

    private var advancedOptionsSection: some View {
        DisclosureGroup("Advanced Options", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Resolution").font(.subheadline).foregroundColor(.secondary)
                    Picker("Resolution", selection: $selectedResolution) {
                        ForEach(availableResolutions) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }

                VStack(alignment: .leading) {
                    Text("Codec").font(.subheadline).foregroundColor(.secondary)
                    Picker("Codec", selection: $selectedCodec) {
                        ForEach(CodecOption.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }

                VStack(alignment: .leading) {
                    Text("Frame Rate: \(Int(targetFrameRate)) fps")
                        .font(.subheadline).foregroundColor(.secondary)
                    Slider(value: $targetFrameRate, in: 15...60, step: 1)
                        .onChange(of: targetFrameRate) { _ in saveSettings() }
                }
            }
            .padding(.top, 8)
            .onChange(of: selectedResolution) { _ in
                updateEstimatedSize()
                saveSettings()
            }
            .onChange(of: selectedCodec) { _ in saveSettings() }
        }
        .padding(.horizontal)
    }

    private var compressButtonSection: some View {
        Button(action: compressVideo) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("Compress Video")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal)
    }

    private var compressingSection: some View {
        VStack(spacing: 8) {
            ProgressView(value: compressionProgress)
            Text("Compressing... \(Int(compressionProgress * 100))%")
                .font(.caption)
            Button("Cancel", role: .destructive) { cancelCompression() }
                .font(.footnote)
                .padding(.top, 4)
                .accessibilityLabel("Cancel compression")
        }
        .padding(.horizontal)
    }

    private func completedSection(compressedURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compression complete")
                .font(.subheadline)
                .foregroundColor(.secondary)

            savingsText

            actionsCard(compressedURL: compressedURL)

            Button("Compress Another Video") { resetUI() }
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var savingsText: some View {
        if compressedFileSize > 0 && originalFileSize > 0 {
            let savingsPercent = Int((1 - Double(compressedFileSize) / Double(originalFileSize)) * 100)
            let sizeLine = "\(formatBytes(originalFileSize)) → \(formatBytes(compressedFileSize))"
            let suffix = savingsPercent > 0 ? " (\(savingsPercent)% smaller)" : ""
            Text(sizeLine + suffix)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func actionsCard(compressedURL: URL) -> some View {
        VStack(spacing: 0) {
            previewRow(compressedURL: compressedURL)
            Divider()
            saveRow
            Divider()
            shareRow
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private func previewRow(compressedURL: URL) -> some View {
        Button(action: {
            previewItem = PreviewItem(player: AVPlayer(url: compressedURL))
        }) {
            Label("Preview", systemImage: "play.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }

    private var saveRow: some View {
        let title = didSaveToPhotos ? "Saved to Photos" : "Save to Photos"
        let icon = didSaveToPhotos ? "checkmark" : "square.and.arrow.down"
        return Button(action: saveToPhotos) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(didSaveToPhotos ? .secondary : .primary)
        .disabled(didSaveToPhotos)
    }

    private var shareRow: some View {
        Button(action: { showingShareSheet = true }) {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }

    @ViewBuilder
    private var messagesSection: some View {
        if let error = errorMessage {
            Text(error).foregroundColor(.red).padding()
        }
        if let success = saveSuccessMessage {
            Label(success, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
    }

    private func applyPreset(_ preset: CompressionPreset) {
        isApplyingPreset = true
        selectedPreset = preset
        compressionLevel = preset.compressionLevel
        selectedResolution = preset.resolution
        selectedCodec = preset.codec
        targetFrameRate = preset.frameRate
        updateEstimatedSize()
        saveSettings()
        isApplyingPreset = false
    }

    private func loadVideo(url: URL) {
        selectedVideoURL = url
        player = AVPlayer(url: url)
        selectedPreset = nil

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            originalFileSize = attributes[.size] as? Int64 ?? 0
        } catch { originalFileSize = 0 }

        // Reset before loading, so a video whose track fails to load doesn't
        // silently inherit the previous video's dimensions/bitrate.
        originalBitrate = 0
        originalSize = .zero

        let asset = AVAsset(url: url)
        Task {
            do {
                let duration = try await asset.load(.duration)
                videoDuration = duration.seconds
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    originalBitrate = Double(try await track.load(.estimatedDataRate))
                    let naturalSize = try await track.load(.naturalSize)
                    let preferredTransform = try await track.load(.preferredTransform)
                    // Report the on-screen (post-rotation) resolution, not the raw
                    // untransformed track size — e.g. a portrait video should read
                    // "1080 x 1920", not "1920 x 1080".
                    let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                    originalSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
                } else {
                    errorMessage = "This video has no readable video track"
                }
                if !availableResolutions.contains(selectedResolution) {
                    selectedResolution = .original
                }
                updateEstimatedSize()
            } catch {
                // Reset so the "Select Video" button reappears instead of leaving
                // the user stuck on a video that failed to load with no way back.
                videoDuration = 0
                player = nil
                selectedVideoURL = nil
                errorMessage = "Couldn't load this video: \(error.localizedDescription)"
            }
        }
    }

    private func updateEstimatedSize() {
        guard originalFileSize > 0, videoDuration > 0 else { estimatedOutputSize = 0; return }
        
        var effectiveBitrate = targetBitrate
        if let targetSize = selectedResolution.dimensions, originalSize.width > 0 {
            let scale = (targetSize.width * targetSize.height) / (originalSize.width * originalSize.height)
            effectiveBitrate = targetBitrate * scale
        }
        estimatedOutputSize = Int64(effectiveBitrate * 1000 * videoDuration / 8)
    }

    private func compressVideo() {
        guard let inputURL = selectedVideoURL else { return }

        // A prior compressed file that was never explicitly saved/reset would
        // otherwise be silently orphaned on disk once we overwrite compressedVideoURL.
        if let oldURL = compressedVideoURL {
            try? FileManager.default.removeItem(at: oldURL)
        }

        let runID = UUID()
        currentRunID = runID
        isCompressing = true
        compressionProgress = 0
        compressedVideoURL = nil
        compressedFileSize = 0
        didSaveToPhotos = false
        errorMessage = nil
        saveSuccessMessage = nil

        compressWithReaderWriter(
            inputURL: inputURL,
            runID: runID,
            targetBitrate: targetBitrate,
            resolution: selectedResolution,
            codec: selectedCodec,
            frameRate: targetFrameRate
        )
    }

    private func compressWithReaderWriter(
        inputURL: URL,
        runID: UUID,
        targetBitrate: Double,
        resolution: ResolutionOption,
        codec: CodecOption,
        frameRate: Double
    ) {
        let asset = AVAsset(url: inputURL)

        Task {
            do {
                let duration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    await MainActor.run {
                        if currentRunID == runID {
                            errorMessage = "No video track found"
                            isCompressing = false
                        }
                    }
                    return
                }

                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)

                // naturalSize is in the track's untransformed coordinate space; apply the
                // transform to get the actual on-screen orientation (e.g. portrait video
                // recorded with landscape naturalSize + a 90° rotation).
                let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let displaySize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

                var outputSize = displaySize
                if let dims = resolution.dimensions {
                    // `dimensions` is always landscape-convention (width >= height);
                    // orient it to match displaySize before comparing, or a portrait
                    // source gets scaled against the wrong axes.
                    let targetSize = displaySize.width < displaySize.height
                        ? CGSize(width: dims.height, height: dims.width)
                        : dims
                    // Cap at 1.0 — a target larger than the source would upscale
                    // (bigger file, no quality gain) instead of compressing.
                    let scale = min(1.0, min(targetSize.width / displaySize.width, targetSize.height / displaySize.height))
                    outputSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
                }
                // H.264/HEVC encoders require even pixel dimensions.
                outputSize = CGSize(
                    width: (outputSize.width / 2).rounded(.down) * 2,
                    height: (outputSize.height / 2).rounded(.down) * 2
                )

                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = outputSize
                videoComposition.renderScale = 1.0
                videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(frameRate))

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

                // The rotation transform alone maps content onto `displaySize`; scale it
                // down to `outputSize` too, or downscaled output renders outside the
                // (smaller) render canvas and shows up blank/cropped.
                let scaleX = outputSize.width / displaySize.width
                let scaleY = outputSize.height / displaySize.height
                let renderTransform = preferredTransform.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

                let transformer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                transformer.setTransform(renderTransform, at: .zero)

                instruction.layerInstructions = [transformer]
                videoComposition.instructions = [instruction]

                let reader = try AVAssetReader(asset: asset)
                await MainActor.run { activeAssetReader = reader }

                let videoCompositionOutput = AVAssetReaderVideoCompositionOutput(
                    videoTracks: videoTracks,
                    videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                )
                videoCompositionOutput.videoComposition = videoComposition
                videoCompositionOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(videoCompositionOutput) else {
                    await MainActor.run {
                        if currentRunID == runID {
                            errorMessage = "Failed to configure video reader"
                            isCompressing = false
                        }
                    }
                    return
                }
                reader.add(videoCompositionOutput)

                var audioOutput: AVAssetReaderTrackOutput?
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if let audioTrack = audioTracks.first {
                    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                    output.alwaysCopiesSampleData = false
                    if reader.canAdd(output) {
                        reader.add(output)
                        audioOutput = output
                    }
                }

                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("compressed_\(UUID().uuidString).mp4")
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                await MainActor.run {
                    activeAssetWriter = writer
                    activeOutputURL = outputURL
                }

                let hevcSupported = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
                let videoCodec: AVVideoCodecType = (codec == .hevc && hevcSupported) ? .hevc : .h264
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: videoCodec,
                    AVVideoWidthKey: Int(outputSize.width),
                    AVVideoHeightKey: Int(outputSize.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(targetBitrate * 1000),
                        AVVideoExpectedSourceFrameRateKey: Int(frameRate),
                        AVVideoMaxKeyFrameIntervalKey: Int(frameRate) * 2
                    ]
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = false
                videoInput.transform = .identity
                guard writer.canAdd(videoInput) else {
                    await MainActor.run {
                        if currentRunID == runID {
                            errorMessage = "Failed to configure video writer"
                            isCompressing = false
                        }
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                writer.add(videoInput)

                var audioInput: AVAssetWriterInput?
                if audioOutput != nil {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                    }
                }

                guard reader.startReading() else {
                    await MainActor.run {
                        if currentRunID == runID {
                            errorMessage = reader.error?.localizedDescription ?? "Failed to start reading"
                            isCompressing = false
                        }
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                guard writer.startWriting() else {
                    await MainActor.run {
                        if currentRunID == runID {
                            errorMessage = writer.error?.localizedDescription ?? "Failed to start writing"
                            isCompressing = false
                        }
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                writer.startSession(atSourceTime: .zero)

                let videoQueue = DispatchQueue(label: "com.videocompressor.writer.video")
                let audioQueue = DispatchQueue(label: "com.videocompressor.writer.audio")
                let group = DispatchGroup()
                let totalSeconds = duration.seconds

                group.enter()
                var lastReportedPercent = -1
                var videoFinished = false
                func finishVideo() {
                    guard !videoFinished else { return }
                    videoFinished = true
                    videoInput.markAsFinished()
                    group.leave()
                }
                videoInput.requestMediaDataWhenReady(on: videoQueue) {
                    // Re-check status on every iteration: cancelReading()/cancelWriting()
                    // can flip these from another thread mid-loop, and appending to an
                    // already-cancelled writer input throws an uncaught exception.
                    while !videoFinished && videoInput.isReadyForMoreMediaData {
                        guard reader.status == .reading, writer.status == .writing else {
                            finishVideo()
                            break
                        }
                        if let sampleBuffer = videoCompositionOutput.copyNextSampleBuffer() {
                            guard writer.status == .writing else {
                                finishVideo()
                                break
                            }
                            videoInput.append(sampleBuffer)
                            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            let progress = totalSeconds > 0 ? CMTimeGetSeconds(pts) / totalSeconds : 0
                            // Dispatching to the main thread on every single frame (thousands
                            // for a multi-minute video) can saturate it and make the UI appear
                            // to freeze; only update when the displayed percentage changes.
                            let percent = Int(min(max(progress, 0), 1) * 100)
                            if percent != lastReportedPercent {
                                lastReportedPercent = percent
                                DispatchQueue.main.async {
                                    if currentRunID == runID {
                                        compressionProgress = min(max(progress, 0), 1)
                                    }
                                }
                            }
                        } else {
                            finishVideo()
                            break
                        }
                    }
                }

                if let audioOutput, let audioInput {
                    group.enter()
                    var audioFinished = false
                    func finishAudio() {
                        guard !audioFinished else { return }
                        audioFinished = true
                        audioInput.markAsFinished()
                        group.leave()
                    }
                    audioInput.requestMediaDataWhenReady(on: audioQueue) {
                        while !audioFinished && audioInput.isReadyForMoreMediaData {
                            guard reader.status == .reading, writer.status == .writing else {
                                finishAudio()
                                break
                            }
                            if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                                guard writer.status == .writing else {
                                    finishAudio()
                                    break
                                }
                                audioInput.append(sampleBuffer)
                            } else {
                                finishAudio()
                                break
                            }
                        }
                    }
                }

                group.notify(queue: .global()) {
                    // A late callback from a run the user already cancelled (and possibly
                    // replaced with a new one via cancelCompression()/compressVideo())
                    // must not clobber a newer run's UI state — runID is the single
                    // source of truth for "is this callback still for the active run".
                    if reader.status == .failed || reader.status == .cancelled {
                        writer.cancelWriting()
                        try? FileManager.default.removeItem(at: outputURL)
                        DispatchQueue.main.async {
                            guard currentRunID == runID else { return }
                            if reader.status == .failed {
                                errorMessage = reader.error?.localizedDescription ?? "Reading failed"
                            }
                            isCompressing = false
                            compressionProgress = 0
                            activeAssetReader = nil
                            activeAssetWriter = nil
                            activeOutputURL = nil
                        }
                        return
                    }
                    writer.finishWriting {
                        DispatchQueue.main.async {
                            guard currentRunID == runID else { return }
                            isCompressing = false
                            compressionProgress = 1.0
                            activeAssetReader = nil
                            activeAssetWriter = nil
                            activeOutputURL = nil
                            if writer.status == .completed {
                                compressedVideoURL = outputURL
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path) {
                                    compressedFileSize = attrs[.size] as? Int64 ?? 0
                                }
                            } else {
                                try? FileManager.default.removeItem(at: outputURL)
                                if writer.status != .cancelled {
                                    errorMessage = writer.error?.localizedDescription ?? "Compression failed"
                                }
                            }
                        }
                    }
                }

            } catch {
                await MainActor.run {
                    if currentRunID == runID {
                        errorMessage = error.localizedDescription
                        isCompressing = false
                    }
                }
            }
        }
    }

    private func saveToPhotos() {
        guard let url = compressedVideoURL else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            saveSuccessMessage = "Saved to Photos"
                            didSaveToPhotos = true
                        } else {
                            errorMessage = error?.localizedDescription ?? "Failed to save"
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    errorMessage = "Photo library access denied"
                }
            }
        }
    }

    private func resetUI() {
        if let inputURL = selectedVideoURL {
            try? FileManager.default.removeItem(at: inputURL)
        }
        if let outputURL = compressedVideoURL {
            try? FileManager.default.removeItem(at: outputURL)
        }

        selectedVideoURL = nil
        player = nil
        videoDuration = 0
        originalFileSize = 0
        originalBitrate = 0
        originalSize = .zero
        estimatedOutputSize = 0
        selectedPreset = nil
        compressedVideoURL = nil
        compressedFileSize = 0
        previewItem = nil
        isCompressing = false
        compressionProgress = 0
        activeAssetReader = nil
        activeAssetWriter = nil
        activeOutputURL = nil
        currentRunID = nil
        errorMessage = nil
        saveSuccessMessage = nil
        didSaveToPhotos = false
        showAdvanced = false

        // Restore the user's last-used compression settings rather than
        // hardcoded defaults, so preferences persist across videos too.
        compressionLevel = 0.5
        selectedResolution = .original
        selectedCodec = .h264
        targetFrameRate = 30
        loadSettings()
    }

    private func cancelCompression() {
        // Tell the reader/writer to stop, but don't wait on their background
        // callback loop to notice — it may be idle waiting on the system and
        // not fire again promptly, leaving the UI stuck on "Compressing...".
        // Reset the UI immediately instead; the loop's eventual cleanup is
        // a no-op by the time it runs since these are already nil'd.
        activeAssetReader?.cancelReading()
        activeAssetWriter?.cancelWriting()
        if let url = activeOutputURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeAssetReader = nil
        activeAssetWriter = nil
        activeOutputURL = nil
        // Invalidate the run so its late completion callback (guarded by
        // `currentRunID == runID`) becomes a no-op instead of clobbering
        // whatever run replaces this one.
        currentRunID = nil
        isCompressing = false
        compressionProgress = 0
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Views
struct FullScreenVideoPlayer: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AVPlayerControllerRepresentable(player: player)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding()
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

// SwiftUI's VideoPlayer (AVKit) can render a black screen for local file URLs in
// some ZStack/fullScreenCover combinations; AVPlayerViewController is the more
// reliable, standard way to embed playback.
struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var selectedVideoURL: URL?
    var onVideoSelected: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                if let url = url {
                    // A name derived from the source file (e.g. camera-generated
                    // "IMG_0001.MOV") can collide with a leftover temp file from a
                    // prior pick; a UUID guarantees a fresh destination every time.
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                    } catch {
                        return
                    }
                    DispatchQueue.main.async {
                        self.parent.selectedVideoURL = tempURL
                        self.parent.onVideoSelected(tempURL)
                    }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}