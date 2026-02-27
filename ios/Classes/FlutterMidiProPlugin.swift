import Flutter
import CoreMIDI
import AVFAudio
import AVFoundation
import CoreAudio

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
  // 每个 soundfont 使用 1 个引擎 + 16 个 sampler 节点，替代原来 16 个独立 AVAudioEngine
  var audioEngines: [Int: AVAudioEngine] = [:]
  var soundfontIndex = 1
  var soundfontSamplers: [Int: [AVAudioUnitSampler]] = [:]
  var soundfontURLs: [Int: URL] = [:]
  
  // MIDI Playback properties
  var midiClient: MIDIClientRef = 0
  var musicPlayers: [Int: MusicPlayer] = [:]
  var musicSequences: [Int: MusicSequence] = [:]
  var midiEndpoints: [Int: MIDIEndpointRef] = [:]
  var pollingTimers: [Int: Timer] = [:]
  weak var flutterChannel: FlutterMethodChannel?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
    let instance = FlutterMidiProPlugin()
    instance.flutterChannel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }
  
  public override init() {
    super.init()
    setupAudioSessionNotifications()
    MIDIClientCreate("FlutterMidiProClient" as CFString, nil, nil, &self.midiClient)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
    if midiClient != 0 {
      MIDIClientDispose(midiClient)
    }
  }
  
  private func setupAudioSessionNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }
  
  @objc private func handleAudioSessionInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    switch type {
    case .began:
      break
    case .ended:
      var shouldResume = true
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        shouldResume = options.contains(.shouldResume)
      }
      
      if shouldResume {
        restartAudioEngines()
      }
    @unknown default:
      break
    }
  }
  
  private func restartAudioEngines() {
    for (sfId, engine) in audioEngines {
      if !engine.isRunning {
        do {
          try engine.start()
        } catch {
          print("Failed to restart audio engine for sfId \(sfId): \(error)")
        }
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadSoundfont":
        let args = call.arguments as! [String: Any]
        let path = args["path"] as! String
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int
        let url = URL(fileURLWithPath: path)

        // 单一 AVAudioEngine + 16 个 sampler 节点
        // 原来 16 个独立引擎的写法会创建 16 个独立的 AudioUnit 图和 I/O 线程，
        // 合并为 1 个引擎可减少 ~93% 的引擎开销
        let audioEngine = AVAudioEngine()
        let mainMixer = audioEngine.mainMixerNode
        var chSamplers: [AVAudioUnitSampler] = []

        let isPercussion = (bank == 128)
        let bankMSB: UInt8 = isPercussion ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
        let bankLSB: UInt8 = isPercussion ? 0 : UInt8(bank)

        for _ in 0...15 {
            let sampler = AVAudioUnitSampler()
            audioEngine.attach(sampler)
            // 所有 sampler 逗通到同一个 mainMixer，共用一个输出链
            audioEngine.connect(sampler, to: mainMixer, format: nil)
            do {
                try sampler.loadSoundBankInstrument(at: url, program: UInt8(program), bankMSB: bankMSB, bankLSB: bankLSB)
            } catch {
                result(FlutterError(code: "SOUND_FONT_LOAD_FAILED1", message: "Failed to load soundfont", details: nil))
                return
            }
            chSamplers.append(sampler)
        }

        // 所有节点 attach 完成后才启动引擎，避免多次引擎重启
        do {
            try audioEngine.start()
        } catch {
            result(FlutterError(code: "AUDIO_ENGINE_START_FAILED", message: "Failed to start audio engine", details: nil))
            return
        }

        soundfontSamplers[soundfontIndex] = chSamplers
        soundfontURLs[soundfontIndex] = url
        audioEngines[soundfontIndex] = audioEngine
        soundfontIndex += 1
        result(soundfontIndex-1)
    case "stopAllNotes":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]
        if soundfontSampler == nil {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        soundfontSampler!.forEach { (sampler) in
            for channel in 0...15 {
                sampler.sendController(64, withValue: 0, onChannel: UInt8(channel))
                sampler.sendController(120, withValue: 0, onChannel: UInt8(channel))
            }
        }
        result(nil)
    case "controlChange":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let controller = args["controller"] as! Int
        let value = args["value"] as! Int
        guard let sampler = soundfontSamplers[sfId]?[channel] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
            return
        }
        sampler.sendController(UInt8(controller), withValue: UInt8(value), onChannel: UInt8(channel))
        result(nil)
    case "selectInstrument":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        let soundfontUrl = soundfontURLs[sfId]!
        do {
            let isPercussion = (bank == 128)
            let bankMSB: UInt8 = isPercussion ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
            let bankLSB: UInt8 = isPercussion ? 0 : UInt8(bank)
            
            try soundfontSampler.loadSoundBankInstrument(at: soundfontUrl, program: UInt8(program), bankMSB: bankMSB, bankLSB: bankLSB)
        } catch {
            result(FlutterError(code: "SOUND_FONT_LOAD_FAILED2", message: "Failed to load soundfont", details: nil))
            return
        }
        soundfontSampler.sendProgramChange(UInt8(program), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(bank), onChannel: UInt8(channel))
        result(nil)
    case "playNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let note = args["key"] as! Int
        let velocity = args["velocity"] as! Int
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        soundfontSampler.startNote(UInt8(note), withVelocity: UInt8(velocity), onChannel: UInt8(channel))
        result(nil)
    case "stopNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let note = args["key"] as! Int
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        soundfontSampler.stopNote(UInt8(note), onChannel: UInt8(channel))
        result(nil)
    case "unloadSoundfont":
        let args = call.arguments as! [String:Any]
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]
        if soundfontSampler == nil {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        internalStopMidiFile(sfId: sfId)
        audioEngines[sfId]?.stop() // 单引擎直接调用 stop()
        audioEngines.removeValue(forKey: sfId)
        soundfontSamplers.removeValue(forKey: sfId)
        soundfontURLs.removeValue(forKey: sfId)
        result(nil)
    case "dispose":
        for (sfId, _) in audioEngines {
            internalStopMidiFile(sfId: sfId)
        }
        // 单引擎架构：直接调用 stop()，无需嵌套 forEach
        audioEngines.forEach { (_, engine) in
            engine.stop()
        }
        audioEngines = [:]
        soundfontSamplers = [:]
        result(nil)
    case "playMidiFile":
        let args = call.arguments as! [String: Any]
        guard let sfId = args["sfId"] as? Int,
              let path = args["path"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "sfId and path are required", details: nil))
            return
        }
        let loop = args["loop"] as? Bool ?? true
        
        internalPlayMidiFile(sfId: sfId, path: path, loop: loop, result: result)
    case "pauseMidiFile":
        let args = call.arguments as! [String: Any]
        guard let sfId = args["sfId"] as? Int else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "sfId is required", details: nil))
            return
        }
        if let player = musicPlayers[sfId] {
            var isPlaying: DarwinBoolean = false
            MusicPlayerIsPlaying(player, &isPlaying)
            if isPlaying.boolValue {
                MusicPlayerStop(player)
            }
        }
        result(nil)
    case "resumeMidiFile":
        let args = call.arguments as! [String: Any]
        guard let sfId = args["sfId"] as? Int else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "sfId is required", details: nil))
            return
        }
        if let player = musicPlayers[sfId] {
            MusicPlayerStart(player)
        }
        result(nil)
    case "stopMidiFile":
        let args = call.arguments as! [String: Any]
        guard let sfId = args["sfId"] as? Int else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "sfId is required", details: nil))
            return
        }
        internalStopMidiFile(sfId: sfId)
        result(nil)
    default:
      result(FlutterMethodNotImplemented)
        break
    }
  }
  
  // MARK: - MIDI File Helpers
  
  private func internalPlayMidiFile(sfId: Int, path: String, loop: Bool, result: FlutterResult) {
      internalStopMidiFile(sfId: sfId)
      
      guard let samplers = soundfontSamplers[sfId] else {
          result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found for sfId \(sfId)", details: nil))
          return
      }
      
      var endpoint: MIDIEndpointRef = 0
      
      let block: MIDIReadBlock = { packetList, srcConnRefCon in
          let packets = packetList.pointee
          
          withUnsafePointer(to: packets.packet) { tuplePtr in
              var packetPtr = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: MIDIPacket.self)
              
              for _ in 0 ..< packets.numPackets {
                  let packet = packetPtr.pointee
                  
                  // Copy the data so we can take a buffer pointer to it without mutation
                  let dataTuple = packet.data
                  
                  withUnsafeBytes(of: dataTuple) { bytes in
                      if packet.length > 0 {
                          let statusByte = bytes[0]
                          let channel = Int(statusByte & 0x0F)
                          
                          if channel >= 0 && channel < 16, channel < samplers.count {
                              let sampler = samplers[channel]
                              let data1 = packet.length > 1 ? bytes[1] : 0
                              let data2 = packet.length > 2 ? bytes[2] : 0
                              
                              sampler.sendMIDIEvent(statusByte, data1: data1, data2: data2)
                          }
                      }
                  }
                  
                  let packetSize = MemoryLayout<MIDIPacket>.size - 256 + Int(packet.length)
                  let offset = (packetSize + 3) & ~3
                  
                  // Move to the next packet
                  packetPtr = UnsafeRawPointer(packetPtr).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
              }
          }
      }
      
      var status = MIDIDestinationCreateWithBlock(midiClient, "FlutterMidiProDest" as CFString, &endpoint, block)
      if status != noErr {
          result(FlutterError(code: "MIDI_DEST_FAILED", message: "Failed to create MIDI destination \(status)", details: nil))
          return
      }
      midiEndpoints[sfId] = endpoint
      
      var sequence: MusicSequence?
      status = NewMusicSequence(&sequence)
      guard let seq = sequence, status == noErr else {
          result(FlutterError(code: "SEQ_CREATE_FAILED", message: "Failed to create sequence", details: nil))
          return
      }
      musicSequences[sfId] = seq
      
      let fileURL = URL(fileURLWithPath: path)
      status = MusicSequenceFileLoad(seq, fileURL as CFURL, .midiType, MusicSequenceLoadFlags.smf_ChannelsToTracks)
      if status != noErr {
          result(FlutterError(code: "FILE_LOAD_FAILED", message: "Failed to load midi file", details: nil))
          return
      }
      
      var trackCount: UInt32 = 0
      MusicSequenceGetTrackCount(seq, &trackCount)
      for i in 0..<trackCount {
          var track: MusicTrack?
          MusicSequenceGetIndTrack(seq, i, &track)
          if let trk = track {
              MusicTrackSetDestMIDIEndpoint(trk, endpoint)
          }
      }
      
      var player: MusicPlayer?
      NewMusicPlayer(&player)
      guard let plyr = player else {
          result(FlutterError(code: "PLAYER_CREATE_FAILED", message: "Failed to create player", details: nil))
          return
      }
      musicPlayers[sfId] = plyr
      
      MusicPlayerSetSequence(plyr, seq)
      MusicPlayerStart(plyr)
      
      result(nil)
      
      var seqLength: MusicTimeStamp = 0
      for i in 0..<trackCount {
          var track: MusicTrack?
          MusicSequenceGetIndTrack(seq, i, &track)
          if let trk = track {
              var trkLen: MusicTimeStamp = 0
              var propSz = UInt32(MemoryLayout<MusicTimeStamp>.size)
              MusicTrackGetProperty(trk, kSequenceTrackProperty_TrackLength, &trkLen, &propSz)
              seqLength = max(seqLength, trkLen)
          }
      }
      
      // 轮询间隔从 100ms 改为 1000ms：减少 90% 的后台 CPU 唤醒
      // 对于几分钟长的 MIDI 曲，1s 精度完全足够，不影响用户体验
      let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
          guard let self = self, let p = self.musicPlayers[sfId] else {
              t.invalidate()
              return
          }
          
          var isPlaying: DarwinBoolean = false
          MusicPlayerIsPlaying(p, &isPlaying)
          var time: MusicTimeStamp = 0
          MusicPlayerGetTime(p, &time)
          
          if !isPlaying.boolValue || time >= seqLength {
              if loop {
                  MusicPlayerSetTime(p, 0)
                  MusicPlayerStart(p)
              } else {
                  t.invalidate()
                  self.pollingTimers.removeValue(forKey: sfId)
                  DispatchQueue.main.async {
                      self.flutterChannel?.invokeMethod("onMidiPlayerCompleted", arguments: ["sfId": sfId])
                  }
              }
          }
      }
      pollingTimers[sfId] = timer
  }
  
  private func internalStopMidiFile(sfId: Int) {
      pollingTimers[sfId]?.invalidate()
      pollingTimers.removeValue(forKey: sfId)
      
      if let player = musicPlayers[sfId] {
          MusicPlayerStop(player)
          DisposeMusicPlayer(player)
          musicPlayers.removeValue(forKey: sfId)
      }
      
      if let seq = musicSequences[sfId] {
          DisposeMusicSequence(seq)
          musicSequences.removeValue(forKey: sfId)
      }
      
      if let endpoint = midiEndpoints[sfId] {
          MIDIEndpointDispose(endpoint)
          midiEndpoints.removeValue(forKey: sfId)
      }
  }
}
