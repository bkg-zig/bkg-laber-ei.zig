"""M0-Prototyp: Pocket-TTS (deutsches INT4-Bundle) mit onnxruntime 1.31, CPU.

Beweise:
 1. Session-Erzeugung für alle vier Graphen (text_conditioner fp32,
    flow_lm_main int4/MatMulNBits, flow_lm_flow int8, mimi_decoder int8).
 2. Voice-State aus voices/alba.safetensors via bundle.json-Manifest.
 3. Autoregressive Latent-Generierung + Mimi-Decoding -> WAV (24 kHz).
 4. TTFB-Messung (Zeit bis zum ersten Audiofragment) und RTF.

Hinweis: Kein abgestimmtes Referenzskript; dies ist die eigenständige
M0-Verifikation der Protokoll-/Laufzeitkompatibilität.
"""

import json
import os
import sys
import time
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort
import sentencepiece as spm
from safetensors.numpy import load_file

BUNDLE = Path(__file__).parent / "models"
TEXT_DEFAULT = "Guten Tag. Dies ist ein Test der Sprachausgabe für das BKG System."


def numpy_dtype(name: str):
    return {"float32": np.float32, "float16": np.float16,
            "int64": np.int64, "bool": np.bool_}[name]


def filled(shape, dtype, fill):
    if fill == "nan":
        return np.full(shape, np.nan, dtype=dtype)
    if fill == "ones":
        return np.ones(shape, dtype=dtype)
    return np.zeros(shape, dtype=dtype)


class Engine:
    def __init__(self, lsd_steps=4, temperature=0.7):
        meta = json.loads((BUNDLE / "bundle.json").read_text())
        self.meta = meta
        self.sample_rate = int(meta["sample_rate"])
        self.frame_rate = float(meta["frame_rate"])
        self.latent_dim = int(meta["latent_dim"])
        self.cond_dim = int(meta["conditioning_dim"])
        self.lsd_steps = lsd_steps
        self.temperature = temperature
        self.flow_manifest = meta["flow_lm_state_manifest"]
        self.mimi_manifest = meta["mimi_state_manifest"]

        opts = ort.SessionOptions()
        opts.intra_op_num_threads = min(os.cpu_count() or 2, 4)
        opts.inter_op_num_threads = 1
        prov = ["CPUExecutionProvider"]

        t0 = time.perf_counter()
        self.tc = ort.InferenceSession(str(BUNDLE / "text_conditioner.onnx"), opts, prov)
        self.main = ort.InferenceSession(str(BUNDLE / "flow_lm_main_int4.onnx"), opts, prov)
        self.flow = ort.InferenceSession(str(BUNDLE / "flow_lm_flow_int8.onnx"), opts, prov)
        self.dec = ort.InferenceSession(str(BUNDLE / "mimi_decoder_int8.onnx"), opts, prov)
        self.load_s = time.perf_counter() - t0

        self.tok = spm.SentencePieceProcessor()
        self.tok.Load(str(BUNDLE / meta["tokenizer_file"]))

        dt = 1.0 / lsd_steps
        self.st = [np.array([[j / lsd_steps]], np.float32) for j in range(lsd_steps)]
        self.tt = [np.array([[j / lsd_steps + dt]], np.float32) for j in range(lsd_steps)]

    def init_state(self, manifest):
        return {e["input_name"]: filled(e["shape"], numpy_dtype(e["dtype"]), e["fill"])
                for e in manifest}

    def update_state(self, state, result, manifest, offset):
        for e in manifest:
            state[e["input_name"]] = result[offset + e["index"]]

    def derive_step(self, mstate):
        if "step" in mstate:
            return np.asarray(mstate["step"], np.int64).reshape(1)
        if "offset" in mstate and "end_offset" not in mstate:
            return np.asarray(mstate["offset"], np.int64).reshape(1)
        if "current_end" in mstate:
            return np.array([mstate["current_end"].shape[0]], np.int64)
        raise KeyError("no step source")

    def adapt(self, tensor, entry):
        want_shape = list(tensor.shape)
        if len(want_shape) < len(entry["shape"]):
            want_shape = [1] * (len(entry["shape"]) - len(want_shape)) + want_shape
        out = np.zeros(entry["shape"], dtype=numpy_dtype(entry["dtype"]))
        idx = tuple(slice(0, min(a, b)) for a, b in zip(tensor.shape, out.shape))
        out[idx] = tensor[idx].astype(out.dtype)
        return out

    def voice_state(self, voice="alba"):
        mstate = {}
        for k, v in load_file(str(BUNDLE / f"{voice}.safetensors")).items():
            mod, key = k.rsplit("/", 1)
            mstate.setdefault(mod, {})[key] = v
        state = self.init_state(self.flow_manifest)
        for e in self.flow_manifest:
            ms = mstate.get(e["module"], {})
            t = ms.get(e["key"])
            if t is None:
                t = self.derive_step(ms)
            state[e["input_name"]] = self.adapt(t, e)
        return state

    def prepare_text(self, text):
        text = text.strip().replace("\n", " ").replace(";", ",")
        if not text[0].isupper():
            text = text[0].upper() + text[1:]
        if text[-1].isalnum():
            text += "."
        return text

    def synthesize(self, text, voice_state, max_frames=250, frames_after_eos=3):
        text = self.prepare_text(text)
        toks = np.array(self.tok.Encode(text), np.int64).reshape(1, -1)
        emb = self.tc.run(None, {"token_ids": toks})[0]
        state = {k: v.copy() for k, v in voice_state.items()}
        empty_seq = np.zeros((1, 0, self.latent_dim), np.float32)
        res = self.main.run(None, {"sequence": empty_seq, "text_embeddings": emb, **state})
        self.update_state(state, res, self.flow_manifest, 2)
        empty_txt = np.zeros((1, 0, self.cond_dim), np.float32)

        curr = np.full((1, 1, self.latent_dim), np.nan, np.float32)
        latents, eos_step = [], None
        dt = 1.0 / self.lsd_steps
        for step in range(max_frames):
            res = self.main.run(None, {"sequence": curr, "text_embeddings": empty_txt, **state})
            cond, eos = res[0], res[1]
            self.update_state(state, res, self.flow_manifest, 2)
            if eos[0][0] > -4.0 and eos_step is None:
                eos_step = step
            if eos_step is not None and step >= eos_step + frames_after_eos:
                break
            x = np.random.normal(0, np.sqrt(self.temperature), (1, self.latent_dim)).astype(np.float32)
            for s, t in zip(self.st, self.tt):
                x = x + self.flow.run(None, {"c": cond, "s": s, "t": t, "x": x})[0] * dt
            latent = x.reshape(1, 1, self.latent_dim)
            latents.append(latent)
            curr = latent
        if not latents:
            return np.zeros(0, np.float32)

        dec_state = self.init_state(self.mimi_manifest)
        audio = []
        stack = np.concatenate(latents, axis=1)
        for i in range(0, stack.shape[1], 12):
            chunk = stack[:, i:i + 12, :]
            r = self.dec.run(None, {"latent": chunk, **dec_state})
            self.update_state(dec_state, r, self.mimi_manifest, 1)
            audio.append(r[0].reshape(-1))
        return np.concatenate(audio)


def write_wav(path, audio, sr):
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else TEXT_DEFAULT
    eng = Engine()
    vs = eng.voice_state("alba")
    print(f"[M0] model_load_seconds={eng.load_s:.2f}")

    # TTFB: Zeit bis zum ersten vollständigen Frame inkl. Decoder-Lauf
    t0 = time.perf_counter()
    first = eng.synthesize("Hallo Welt.", vs, max_frames=10, frames_after_eos=2)
    ttfb_like = time.perf_counter() - t0
    print(f"[M0] short_probe_audio_sec={first.size/eng.sample_rate:.2f} probe_wall={ttfb_like:.2f}s")

    t0 = time.perf_counter()
    audio = eng.synthesize(text, vs)
    wall = time.perf_counter() - t0
    dur = audio.size / eng.sample_rate
    rms = float(np.sqrt(np.mean(audio ** 2))) if audio.size else 0.0
    write_wav("/tmp/m0_output.wav", audio, eng.sample_rate)
    print(f"[M0] text={text!r}")
    print(f"[M0] audio_seconds={dur:.2f} wall_seconds={wall:.2f} rtf={wall/max(dur,1e-6):.2f} rms={rms:.4f}")
    print(f"[M0] wav=/tmp/m0_output.wav")
    assert audio.size > 0 and rms > 0.01, "Stille oder kein Audio – Prototyp fehlgeschlagen"
    print("[M0] PASS: echte 24kHz-Audioausgabe erzeugt")


if __name__ == "__main__":
    main()
