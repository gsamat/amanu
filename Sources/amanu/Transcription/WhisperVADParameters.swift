import whisper

/// One opt-in profile, using whisper.cpp's standard Silero parameters.
/// Keeping it separate makes the native boundary testable without ASR weights.
enum WhisperVADParameters {
    static func apply(to params: inout whisper_full_params, modelPath: UnsafePointer<CChar>?) {
        params.vad = modelPath != nil
        params.vad_model_path = modelPath
        guard modelPath != nil else { return }
        params.vad_params.threshold = 0.5
        params.vad_params.min_speech_duration_ms = 250
        params.vad_params.min_silence_duration_ms = 100
        params.vad_params.max_speech_duration_s = Float.greatestFiniteMagnitude
        params.vad_params.speech_pad_ms = 30
        params.vad_params.samples_overlap = 0.1
    }
}
