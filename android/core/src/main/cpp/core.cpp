#include <jni.h>

extern "C" {
using protect_func = int (*)(void *, int);
using release_func = void (*)(void *);

char *startMihomo(const char *home_directory, const char *config_path,
                  int tun_fd, void *callback);
void stopMihomo();
int isMihomoRunning();
void freeCString(char *value);
void registerCallbacks(protect_func protect, release_func release);
}

namespace {
JavaVM *g_vm = nullptr;
jmethodID g_protect_method = nullptr;

class ScopedEnv {
 public:
  ScopedEnv() {
    if (g_vm->GetEnv(reinterpret_cast<void **>(&env_), JNI_VERSION_1_6) ==
        JNI_OK) {
      return;
    }
    if (g_vm->AttachCurrentThread(&env_, nullptr) == JNI_OK) {
      attached_ = true;
    } else {
      env_ = nullptr;
    }
  }

  ~ScopedEnv() {
    if (attached_) {
      g_vm->DetachCurrentThread();
    }
  }

  JNIEnv *get() const { return env_; }

 private:
  JNIEnv *env_ = nullptr;
  bool attached_ = false;
};

int ProtectSocket(void *callback, int fd) {
  ScopedEnv scoped;
  JNIEnv *env = scoped.get();
  if (env == nullptr || callback == nullptr) {
    return 0;
  }
  const auto protected_socket = env->CallBooleanMethod(
      static_cast<jobject>(callback), g_protect_method, fd);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    return 0;
  }
  return protected_socket == JNI_TRUE ? 1 : 0;
}

void ReleaseCallback(void *callback) {
  ScopedEnv scoped;
  JNIEnv *env = scoped.get();
  if (env != nullptr && callback != nullptr) {
    env->DeleteGlobalRef(static_cast<jobject>(callback));
  }
}
}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_vpn_1ui_1demo_core_MihomoCore_nativeStart(
    JNIEnv *env, jobject, jstring home_directory, jstring config_path,
    jint tun_fd, jobject callback) {
  const char *home = env->GetStringUTFChars(home_directory, nullptr);
  const char *config = env->GetStringUTFChars(config_path, nullptr);
  jobject global_callback = env->NewGlobalRef(callback);
  char *error = startMihomo(home, config, tun_fd, global_callback);
  env->ReleaseStringUTFChars(home_directory, home);
  env->ReleaseStringUTFChars(config_path, config);

  if (error == nullptr) {
    return nullptr;
  }
  jstring result = env->NewStringUTF(error);
  freeCString(error);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_vpn_1ui_1demo_core_MihomoCore_nativeStop(JNIEnv *, jobject) {
  stopMihomo();
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_vpn_1ui_1demo_core_MihomoCore_nativeIsRunning(JNIEnv *,
                                                               jobject) {
  return isMihomoRunning() == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  g_vm = vm;

  jclass callback_class =
      env->FindClass("com/example/vpn_ui_demo/core/TunInterface");
  if (callback_class == nullptr) {
    return JNI_ERR;
  }
  g_protect_method = env->GetMethodID(callback_class, "protect", "(I)Z");
  env->DeleteLocalRef(callback_class);
  if (g_protect_method == nullptr) {
    return JNI_ERR;
  }

  registerCallbacks(&ProtectSocket, &ReleaseCallback);
  return JNI_VERSION_1_6;
}
