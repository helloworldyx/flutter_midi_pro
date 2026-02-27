#include <fluidsynth.h>
#include <jni.h>
#include <map>
#include <unistd.h>

std::map<int, fluid_synth_t *> synths = {};
std::map<int, fluid_audio_driver_t *> drivers = {};
std::map<int, fluid_settings_t *> settings = {};
std::map<int, int> soundfonts = {};
// 用于管理每个 synth 对应的 MIDI 播放器
std::map<int, fluid_player_t *> players = {};
int nextSfId = 1;

// === 核心辅助函数 ===
// audio driver 采用延迟创建 + 主动销毁策略：
//   - loadSoundfont 时不创建 driver，避免空闲时 AudioTrack 持续运行耗电
//   - 需要出声时（playNote / playMidiFile）按需创建
//   - stop 后立即销毁，释放实时音频线程
static void ensure_driver(int sfId) {
  if (synths.find(sfId) == synths.end())
    return;
  if (drivers.find(sfId) == drivers.end() || drivers[sfId] == nullptr) {
    drivers[sfId] = new_fluid_audio_driver(settings[sfId], synths[sfId]);
  }
}

static void destroy_driver(int sfId) {
  if (drivers.find(sfId) != drivers.end() && drivers[sfId] != nullptr) {
    delete_fluid_audio_driver(drivers[sfId]);
    drivers[sfId] = nullptr;
  }
}

extern "C" JNIEXPORT int JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_loadSoundfont(
    JNIEnv *env, jclass clazz, jstring path, jint bank, jint program) {
  settings[nextSfId] = new_fluid_settings();
  fluid_settings_setnum(settings[nextSfId], "synth.gain", 1.0);
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
  // 不再在此处创建 audio driver，改为按需延迟创建以节省电量
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
  // 单音符也需要 audio driver 才能出声
  ensure_driver(sfId);
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

// ==================== MIDI 文件控制模块 ====================

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_playMidiFile(
    JNIEnv *env, jclass clazz, jint sfId, jstring path, jboolean loop) {
  if (synths.find(sfId) == synths.end())
    return;

  const char *nativePath = env->GetStringUTFChars(path, nullptr);

  // 如果已经有播放器在运行，先安全销毁
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
    fluid_player_join(players[sfId]);
    delete_fluid_player(players[sfId]);
  }

  // 按需创建 audio driver（stop 后已被销毁）
  ensure_driver(sfId);

  players[sfId] = new_fluid_player(synths[sfId]);
  fluid_player_add(players[sfId], nativePath);
  fluid_player_set_loop(players[sfId], loop ? -1 : 0);

  // Channel 9 = GM 打击乐通道，必须在播放前切到 bank 128
  fluid_synth_program_select(synths[sfId], 9, soundfonts[sfId], 128, 0);

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
    // resume 时也需要确保 driver 存在
    ensure_driver(sfId);
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
  // 立即切断所有正在发声的音符
  if (synths.find(sfId) != synths.end()) {
    for (int ch = 0; ch < 16; ++ch) {
      fluid_synth_all_sounds_off(synths[sfId], ch);
    }
  }
  // 销毁 audio driver，释放实时音频线程 + AudioTrack
  destroy_driver(sfId);
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

// fluid_player_join 阻塞当前线程直到播放自然结束
// Kotlin 浏这个方法在 IO 调度器上挂起，不占用 CPU，替代轮询
extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_joinMidiFile(
    JNIEnv *env, jclass clazz, jint sfId) {
  if (players.find(sfId) == players.end())
    return;
  // 将当前线程挂起到播放完成，内核层面实现 0 CPU 占用等待
  fluid_player_join(players[sfId]);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_unloadSoundfont(
    JNIEnv *env, jclass clazz, jint sfId) {
  // 卸载前先清理播放器
  if (players.find(sfId) != players.end()) {
    fluid_player_stop(players[sfId]);
    fluid_player_join(players[sfId]);
    delete_fluid_player(players[sfId]);
    players.erase(sfId);
  }

  destroy_driver(sfId);
  delete_fluid_synth(synths[sfId]);
  delete_fluid_settings(settings[sfId]);
  synths.erase(sfId);
  drivers.erase(sfId);
  soundfonts.erase(sfId);
  settings.erase(sfId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_dispose(
    JNIEnv *env, jclass clazz) {
  for (auto const &p : players) {
    fluid_player_stop(p.second);
    fluid_player_join(p.second);
    delete_fluid_player(p.second);
  }
  players.clear();

  for (auto const &x : synths) {
    destroy_driver(x.first);
    delete_fluid_synth(synths[x.first]);
    delete_fluid_settings(settings[x.first]);
  }
  synths.clear();
  drivers.clear();
  soundfonts.clear();
  settings.clear();
}