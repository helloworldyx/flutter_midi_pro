import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_midi_pro/flutter_midi_pro_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

class MidiPro {
  MidiPro();

  Future<int> loadSoundfontAsset({required String assetPath, int bank = 0, int program = 0}) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/${assetPath.split('/').last}');
    if (!tempFile.existsSync()) {
      final byteData = await rootBundle.load(assetPath);
      final buffer = byteData.buffer;
      await tempFile
          .writeAsBytes(buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
    }
    return FlutterMidiProPlatform.instance.loadSoundfont(tempFile.path, bank, program);
  }

  Future<int> loadSoundfontFile({required String filePath, int bank = 0, int program = 0}) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/${filePath.split('/').last}');
    if (!tempFile.existsSync()) {
      final file = File(filePath);
      await file.copy(tempFile.path);
    }
    return FlutterMidiProPlatform.instance.loadSoundfont(tempFile.path, bank, program);
  }

  Future<int> loadSoundfontData({required Uint8List data, int bank = 0, int program = 0}) async {
    final tempDir = await getTemporaryDirectory();
    final randomTempFileName = 'soundfont_${DateTime.now().millisecondsSinceEpoch}.sf2';
    final tempFile = File('${tempDir.path}/$randomTempFileName');
    tempFile.writeAsBytesSync(data);
    return FlutterMidiProPlatform.instance.loadSoundfont(tempFile.path, bank, program);
  }

  Future<void> selectInstrument({
    required int sfId,
    required int program,
    int channel = 0,
    int bank = 0,
  }) async {
    return FlutterMidiProPlatform.instance.selectInstrument(sfId, channel, bank, program);
  }

  Future<void> playNote({
    int channel = 0,
    required int key,
    int velocity = 127,
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.playNote(channel, key, velocity, sfId);
  }

  Future<void> stopNote({
    int channel = 0,
    required int key,
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.stopNote(channel, key, sfId);
  }

  Future<void> stopAllNotes({
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.stopAllNotes(sfId);
  }

  Future<void> controlChange({
    required int controller,
    required int value,
    int channel = 0,
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.controlChange(sfId, channel, controller, value);
  }

  Future<void> setSustain({
    required bool enabled,
    int channel = 0,
    int sfId = 1,
  }) async {
    final value = enabled ? 127 : 0;
    return controlChange(controller: 64, value: value, channel: channel, sfId: sfId);
  }

  Future<void> unloadSoundfont(int sfId) async {
    return FlutterMidiProPlatform.instance.unloadSoundfont(sfId);
  }

  Future<void> dispose() async {
    return FlutterMidiProPlatform.instance.dispose();
  }

  // ==================== 【新增的 MIDI 文件控制 API】 ====================
  
  /// 监听播放完成事件（只在 loop=false 时有效，自然结束触发抛出 sfId）
  Stream<int> get onPlaybackComplete => FlutterMidiProPlatform.instance.onPlaybackComplete;

  /// 播放本地的 .mid 文件。
  Future<void> playMidiFile({
    required String path,
    int sfId = 1,
    bool loop = true,
  }) async {
    return FlutterMidiProPlatform.instance.playMidiFile(sfId, path, loop: loop);
  }

  /// 暂停 MIDI 播放（保持当前时间戳）
  Future<void> pauseMidiFile({
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.pauseMidiFile(sfId);
  }

  /// 恢复 MIDI 播放
  Future<void> resumeMidiFile({
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.resumeMidiFile(sfId);
  }

  /// 彻底停止 MIDI 播放并释放文件
  Future<void> stopMidiFile({
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.stopMidiFile(sfId);
  }

  // ==================== 【音量控制便利方法】 ====================

  /// 设置单个 MIDI channel 的音量（MIDI CC#7 = Channel Volume）
  /// [volume] 范围 0.0 ~ 1.0，内部线性映射到 MIDI 值 0 ~ 127
  /// 复用 controlChange 而非新增 native 方法，降低改动面
  Future<void> setChannelVolume({
    required int sfId,
    required int channel,
    required double volume,
  }) {
    final midiVal = (volume.clamp(0.0, 1.0) * 127).round();
    return controlChange(controller: 7, value: midiVal, channel: channel, sfId: sfId);
  }

  /// 批量设置多个 MIDI channel 的音量
  /// 顺序发送以保证通道顺序一致，调用方无需关心底层 CC#7 细节
  Future<void> setChannelsVolume({
    required int sfId,
    required List<int> channels,
    required double volume,
  }) async {
    for (final ch in channels) {
      await setChannelVolume(sfId: sfId, channel: ch, volume: volume);
    }
  }
}