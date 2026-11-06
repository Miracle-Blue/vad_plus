# Only reached by name from JNI (vad_plus_jni.cpp), so R8 can't see they're used.
-keep class dev.miracle.vad_plus.** { *; }

# ONNX Runtime ships no rules, and its JNI code finds classes by name as well.
# Without this any ORT error aborts the app: FindClass can't see OrtException.
-keep class ai.onnxruntime.** { *; }
