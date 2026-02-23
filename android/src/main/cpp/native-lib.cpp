#include <fluidsynth.h>
#include <jni.h>
#include <map>
#include <unistd.h>

std::map<int, fluid_synth_t *> synths = {};
std::map<int, fluid_audio_driver_t *> drivers = {};
std::map<int, fluid_settings_t *> settings = {};
std::map<int, int> soundfonts = {};
// 【新增】：用于管理每个 synth 对应的 MIDI 播放器
std::map<int, fluid_player_t *> players = {};
int nextSfId = 1;

extern "C" JNIEXPORT int JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_loadSoundfont(
    JNIEnv *env, jclass clazz, jstring path, jint bank, jint program) {
  settings[nextSfId] = new_fluid_settings();
  fluid_settings_setnum(settings[nextSfId], "synth.gain", 1.0);
  // sayısal değerleri uygun setter ile ayarla
  fluid_settings_setint(settings[nextSfId], "audio.period-size", 64);
  fluid_settings_setint(settings[nextSfId], "audio.periods", 4);
  fluid_settings_setint(settings[nextSfId], "audio.realtime-prio", 99);
  fluid_settings_setnum(settings[nextSfId], "synth.sample-rate", 44100.0);
  fluid_settings_setint(settings[nextSfId], "synth.polyphony", 32);

  const char *nativePath = env->GetStringUTFChars(path, nullptr);
  synths[nextSfId] = new_fluid_synth(settings[nextSfId]);
  int sfId = fluid_synth_sfload(synths[nextSfId], nativePath, 0);
  for (int i = 0; i < 16; i++) {
    fluid_synth_program_select(synths[nextSfId], i, sfId, bank, program);
  }
  env->ReleaseStringUTFChars(path, nativePath);
  // Audio driver'ı en son oluştur
  drivers[nextSfId] =
      new_fluid_audio_driver(settings[nextSfId], synths[nextSfId]);
  soundfonts[nextSfId] = sfId;
  nextSfId++;
  return nextSfId - 1;
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_selectInstrument(
    JNIEnv *env, jclass clazz, jint sfId, jint channel, jint bank,
    jint program) {
  fluid_synth_program_select(synths[sfId], channel, soundfonts[sfId], bank,
                             program);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_playNote(
    JNIEnv *env, jclass clazz, jint channel, jint key, jint velocity,
    jint sfId) {
  fluid_synth_noteon(synths[sfId], channel, key, velocity);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopNote(
    JNIEnv *env, jclass clazz, jint channel, jint key, jint sfId) {
  fluid_synth_noteoff(synths[sfId], channel, key);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopAllNotes(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (synths.find(sfId) == synths.end())
    return;
  // Sustain'i kapat ve tüm kanallar için All Sound Off gönder
  for (int ch = 0; ch < 16; ++ch) {
    fluid_synth_cc(synths[sfId], ch, 64, 0);      // Sustain off
    fluid_synth_all_sounds_off(synths[sfId], ch); // Instant cut
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_controlChange(
    JNIEnv *env, jclass clazz, jint sfId, jint channel, jint controller,
    jint value) {
  if (synths.find(sfId) == synths.end())
    return;
  fluid_synth_cc(synths[sfId], channel, controller, value);
}

// ==================== 【新增的 MIDI 文件控制模块】 ====================

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_playMidiFile(
    JNIEnv *env, jclass clazz, jint sfId, jstring path, jboolean loop) {
  // 确保合成器存在
  if (synths.find(sfId) == synths.end())
    return;

  const char *nativePath = env->GetStringUTFChars(path, nullptr);

  // 如果该 sfId 已经有一个播放器在运行，先安全销毁它
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
    fluid_player_join(players[sfId]);
    delete_fluid_player(players[sfId]);
  }

  // 创建新播放器并绑定到对应的合成器
  players[sfId] = new_fluid_player(synths[sfId]);
  fluid_player_add(players[sfId], nativePath);

  // 核心：设置无限循环还是只播放一次
  fluid_player_set_loop(players[sfId], loop ? -1 : 0);

  // Channel 9 = GM 打击乐通道，必须在播放前切到 bank 128
  // 否则 note 36/38/42 会被当作钢琴音符
  fluid_synth_program_select(synths[sfId], 9, soundfonts[sfId], 128, 0);

  // 启动原生播放引擎
  fluid_player_play(players[sfId]);

  env->ReleaseStringUTFChars(path, nativePath);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_pauseMidiFile(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_resumeMidiFile(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (players.find(sfId) != players.end()) {
    fluid_player_play(players[sfId]);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopMidiFile(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
    fluid_player_join(players[sfId]);
    delete_fluid_player(players[sfId]);
    players.erase(sfId);
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_isMidiPlayerPlaying(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (players.find(sfId) == players.end()) {
    return JNI_FALSE;
  }
  int status = fluid_player_get_status(players[sfId]);
  return status == FLUID_PLAYER_PLAYING ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_unloadSoundfont(
    JNIEnv *env, jclass clazz, jint sfId) {
  // 【新增】：卸载音色库前，先清理对应的播放器，防止 C++ 内存泄漏崩溃
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
    fluid_player_join(players[sfId]);
    delete_fluid_player(players[sfId]);
    players.erase(sfId);
  }

  delete_fluid_audio_driver(drivers[sfId]);
  delete_fluid_synth(synths[sfId]);
  synths.erase(sfId);
  drivers.erase(sfId);
  soundfonts.erase(sfId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_dispose(
    JNIEnv *env, jclass clazz) {
  // 【新增】：全局销毁时，清理所有播放器
  for (auto const &p : players) {
    fluid_player_stop(p.second);
    fluid_player_join(p.second);
    delete_fluid_player(p.second);
  }
  players.clear();

  for (auto const &x : synths) {
    delete_fluid_audio_driver(drivers[x.first]);
    delete_fluid_synth(synths[x.first]);
    delete_fluid_settings(settings[x.first]);
  }
  synths.clear();
  drivers.clear();
  soundfonts.clear();
}