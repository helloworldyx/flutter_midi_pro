import 'package:flutter_midi_pro/flutter_midi_pro_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class FlutterMidiProPlatform extends PlatformInterface {
  FlutterMidiProPlatform() : super(token: _token);
  static final Object _token = Object();
  static FlutterMidiProPlatform _instance = MethodChannelFlutterMidiPro();
  static FlutterMidiProPlatform get instance => _instance;

  static set instance(FlutterMidiProPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<int> loadSoundfont(String path, int bank, int program) {
    throw UnimplementedError('loadSoundfont() has not been implemented.');
  }

  Future<void> selectInstrument(int sfId, int channel, int bank, int program) {
    throw UnimplementedError('selectInstrument() has not been implemented.');
  }

  Future<void> playNote(int channel, int key, int velocity, int sfId) {
    throw UnimplementedError('playNote() has not been implemented.');
  }

  Future<void> stopNote(int channel, int key, int sfId) {
    throw UnimplementedError('stopNote() has not been implemented.');
  }

  Future<void> stopAllNotes(int sfId) {
    throw UnimplementedError('stopAllNotes() has not been implemented.');
  }

  Future<void> controlChange(int sfId, int channel, int controller, int value) {
    throw UnimplementedError('controlChange() has not been implemented.');
  }

  Future<void> unloadSoundfont(int sfId) {
    throw UnimplementedError('unloadSoundfont() has not been implemented.');
  }

  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }

  // ==================== 【新增的 MIDI 文件控制接口】 ====================
  Future<void> playMidiFile(int sfId, String path) {
    throw UnimplementedError('playMidiFile() has not been implemented.');
  }

  Future<void> pauseMidiFile(int sfId) {
    throw UnimplementedError('pauseMidiFile() has not been implemented.');
  }

  Future<void> resumeMidiFile(int sfId) {
    throw UnimplementedError('resumeMidiFile() has not been implemented.');
  }

  Future<void> stopMidiFile(int sfId) {
    throw UnimplementedError('stopMidiFile() has not been implemented.');
  }
}