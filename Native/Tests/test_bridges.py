#!/usr/bin/env python3
"""Exercise compiled bridges. Optional real model paths never trigger downloads."""
import argparse
import ctypes as C
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

parser = argparse.ArgumentParser()
parser.add_argument("--build-root", type=Path, default=Path(__file__).resolve().parents[1] / ".build")
parser.add_argument("--whisper-model", type=Path)
parser.add_argument("--wav", type=Path, help="Mono 16 kHz signed 16-bit PCM WAV, up to 120 s")
parser.add_argument("--llama-model", type=Path)
args, unittest_args = parser.parse_known_args()
CALLBACK = C.CFUNCTYPE(C.c_int, C.c_void_p)
NO_CANCEL = CALLBACK(lambda _: 0)
CANCEL = CALLBACK(lambda _: 1)


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.whisper_path = args.build_root / "whisper-linux/libAOWhisper.so"
        cls.llama_path = args.build_root / "llama-linux/libAOLlama.so"
        cls.whisper = C.CDLL(str(cls.whisper_path), mode=os.RTLD_NOW | os.RTLD_LOCAL)
        cls.llama = C.CDLL(str(cls.llama_path), mode=os.RTLD_NOW | os.RTLD_LOCAL)
        cls.whisper.ao_whisper_transcribe.argtypes = [
            C.c_char_p, C.POINTER(C.c_float), C.c_int32, C.c_char_p,
            C.c_char_p, C.c_int32, C.c_int32, CALLBACK, C.c_void_p,
            C.POINTER(C.c_void_p), C.c_void_p, C.c_size_t]
        cls.whisper.ao_whisper_transcribe.restype = C.c_int
        cls.llama.ao_llama_generate.argtypes = [
            C.c_char_p, C.c_char_p, C.c_int32, C.c_int32, C.c_int32,
            C.c_int32, CALLBACK, C.c_void_p, C.POINTER(C.c_void_p), C.c_void_p, C.c_size_t]
        cls.llama.ao_llama_generate.restype = C.c_int
        for library, name in [(cls.whisper, "ao_whisper_free_text"), (cls.llama, "ao_llama_free_text")]:
            getattr(library, name).argtypes = [C.c_void_p]
            getattr(library, name).restype = None

    def whisper_call(self, model=b"/no-such-local-model.bin", pcm=None, cancel=NO_CANCEL, count=None, capacity=256):
        if pcm is None:
            pcm = (C.c_float * 16000)()
        result = C.c_void_p(123)  # bridge must reset caller's output on every failure
        error = C.create_string_buffer(capacity)
        status = self.whisper.ao_whisper_transcribe(
            model, pcm, len(pcm) if count is None else count,
            b"hr", b"Prethodni hrvatski kontekst.", 2, 0, cancel, None,
            C.byref(result), error, capacity)
        text = C.string_at(result.value).decode("utf-8") if result.value else None
        self.whisper.ao_whisper_free_text(result)
        return status, text, error.value

    def llama_call(self, model=b"/no-such-local-model.gguf", prompt=b"test", cancel=NO_CANCEL, context=1024):
        result = C.c_void_p(123)
        error = C.create_string_buffer(256)
        status = self.llama.ao_llama_generate(
            model, prompt, context, 128, 2, 0, cancel, None, C.byref(result), error, len(error))
        text = C.string_at(result.value).decode("utf-8") if result.value else None
        self.llama.ao_llama_free_text(result)
        return status, text, error.value

    def test_only_bridge_symbols_exported(self):
        for path, expected in [
            (self.whisper_path, {"ao_whisper_transcribe", "ao_whisper_free_text"}),
            (self.llama_path, {"ao_llama_generate", "ao_llama_free_text"})]:
            output = subprocess.check_output(["nm", "-D", "--defined-only", str(path)], text=True)
            self.assertEqual({line.split()[-1] for line in output.splitlines()}, expected)

    def test_missing_models_report_failure_with_both_engines_loaded(self):
        for call in [self.whisper_call, self.llama_call]:
            status, text, error = call()
            self.assertEqual(status, 1)
            self.assertIsNone(text)
            self.assertTrue(error)
            self.assertNotIn(b"/no-such", error)

    def test_preflight_cancellation_does_not_load_model(self):
        for call in [self.whisper_call, self.llama_call]:
            status, text, _ = call(cancel=CANCEL)
            self.assertEqual(status, 2)
            self.assertIsNone(text)

    def test_invalid_audio_is_rejected(self):
        self.assertEqual(self.whisper_call(count=0)[0], 1)
        self.assertEqual(self.whisper_call(pcm=(C.c_float * 1)(math.nan))[0], 1)
        self.assertEqual(self.whisper_call(pcm=(C.c_float * 1)(math.inf))[0], 1)

    def test_invalid_context_and_empty_prompt_are_rejected(self):
        self.assertEqual(self.llama_call(context=20000)[0], 1)
        self.assertEqual(self.llama_call(prompt=b"")[0], 1)

    def test_one_byte_error_buffer_is_terminated(self):
        status, text, error = self.whisper_call(capacity=1)
        self.assertEqual((status, text, error), (1, None, b""))

    def test_malformed_local_gguf_reports_error(self):
        with tempfile.NamedTemporaryFile(suffix=".gguf") as model:
            model.write(b"this is not GGUF\x00")
            model.flush()
            status, text, error = self.llama_call(model=os.fsencode(model.name))
        self.assertEqual(status, 1)
        self.assertIsNone(text)
        self.assertTrue(error)

    @unittest.skipUnless(args.whisper_model and args.wav, "No real Whisper model/WAV supplied")
    def test_real_whisper_croatian_wav(self):
        with wave.open(str(args.wav), "rb") as source:
            self.assertEqual((source.getnchannels(), source.getframerate(), source.getsampwidth()), (1, 16000, 2))
            frames = source.readframes(source.getnframes())
        samples = struct.unpack("<" + "h" * (len(frames) // 2), frames)
        pcm = (C.c_float * len(samples))(*(sample / 32768.0 for sample in samples))
        status, text, error = self.whisper_call(os.fsencode(args.whisper_model), pcm)
        self.assertEqual(status, 0, error)
        result = json.loads(text)
        self.assertTrue(result["text"].strip())
        self.assertTrue(result["segments"])
        for segment in result["segments"]:
            self.assertGreaterEqual(segment["start"], 0)
            self.assertGreaterEqual(segment["end"], segment["start"])
            self.assertLessEqual(segment["end"], len(samples) / 16000)

    @unittest.skipUnless(args.llama_model, "No real Qwen3 GGUF supplied")
    def test_real_qwen_generates_croatian_json(self):
        prompt = ("<|im_start|>system\nOdgovori samo JSON objektom. /no_think<|im_end|>\n"
                  "<|im_start|>user\nVrati točno JSON objekt {\"ok\":true}. /no_think<|im_end|>\n"
                  "<|im_start|>assistant\n<think>\n\n</think>\n\n").encode()
        status, text, error = self.llama_call(os.fsencode(args.llama_model), prompt)
        self.assertEqual(status, 0, error)
        result = json.loads(text)
        self.assertEqual(json.loads(result["text"]), {"ok": True})
        self.assertGreater(result["generatedTokens"], 0)
        self.assertGreater(result["promptTokens"], 0)
        self.assertGreater(result["generationSeconds"], 0)


if __name__ == "__main__":
    unittest.main(argv=[__file__, *unittest_args])
