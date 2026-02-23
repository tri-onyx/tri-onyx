"""Voice transcription using NB-Whisper via faster-whisper."""

from __future__ import annotations

import logging
import subprocess

import numpy as np
from faster_whisper import WhisperModel

logger = logging.getLogger(__name__)

# NB-Whisper model name mapping
MODEL_NAMES = {
    "tiny": "NbAiLabBeta/nb-whisper-tiny",
    "small": "NbAiLabBeta/nb-whisper-small",
    "medium": "NbAiLabBeta/nb-whisper-medium",
    "large": "NbAiLabBeta/nb-whisper-large",
}


class Transcriber:
    """Transcribes audio bytes to text using NB-Whisper with lazy model loading."""

    def __init__(self, model_size: str = "tiny", language: str = "no") -> None:
        self._model_size = model_size
        self._language = language
        self._model: WhisperModel | None = None

    def _ensure_model(self) -> WhisperModel:
        if self._model is None:
            model_name = MODEL_NAMES.get(self._model_size, MODEL_NAMES["tiny"])
            logger.info("Loading whisper model: %s", model_name)
            self._model = WhisperModel(
                model_name,
                device="auto",
                compute_type="int8",
            )
            logger.info("Whisper model loaded")
        return self._model

    def transcribe_bytes(self, audio_bytes: bytes) -> str:
        """Convert audio bytes (any format) to text via ffmpeg + whisper."""
        # Convert to 16kHz mono f32le PCM via ffmpeg pipe
        proc = subprocess.run(
            [
                "ffmpeg",
                "-i", "pipe:0",
                "-f", "f32le",
                "-acodec", "pcm_f32le",
                "-ar", "16000",
                "-ac", "1",
                "pipe:1",
            ],
            input=audio_bytes,
            capture_output=True,
            timeout=30,
        )

        if proc.returncode != 0:
            logger.error("ffmpeg conversion failed: %s", proc.stderr.decode(errors="replace")[:500])
            return ""

        pcm_data = np.frombuffer(proc.stdout, dtype=np.float32)
        if len(pcm_data) == 0:
            return ""

        model = self._ensure_model()
        segments, _info = model.transcribe(
            pcm_data,
            language=self._language,
            beam_size=5,
            vad_filter=True,
        )

        return "".join(seg.text for seg in segments).strip()
