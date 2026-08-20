#!/usr/bin/env python3
"""
Embedding sidecar for exo — Qwen3-Embedding-0.6B via MLX.

PASS-4 Area D picked EmbeddingGemma-300M, with Qwen3-Embedding-0.6B (Apache-2.0,
64.33 MMTEB, higher than Gemma's 61.15) as the runner-up and "a genuinely close call".
Qwen3 is used here for a practical reason the research anticipated: **the Gemma license is
not OSI-approved and the weights are gated on HuggingFace**, so it needs an account and a
click-through. Apache-2.0 needs neither, which matters for a 30-year artifact.

Protocol: JSONL in on stdin  {"id": <int>, "text": "..."}
          JSONL out on stdout {"id": <int>, "bits": <n>, "hex": "..."}
Binary quantization happens here so only 32 bytes/vector crosses the boundary.

The model is loaded once per invocation, so exo batches.
"""
import sys, json, argparse
import numpy as np
import mlx.core as mx
from mlx_embeddings.utils import load

MODEL = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

def to_np(v):
    # MLX may hand back bfloat16, which numpy cannot buffer-convert directly.
    return np.array(v.astype(mx.float32))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=256)
    ap.add_argument("--model", default=MODEL)
    a = ap.parse_args()

    model, tok = load(a.model)
    print(json.dumps({"ready": True, "model": a.model, "bits": a.bits}), file=sys.stderr, flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            # still emit something: the reader frames batches by counting replies, and a
            # silent drop here blocks it forever
            print(json.dumps({"id": None, "skip": "badjson"}), flush=True)
            continue
        # explicit end-of-batch marker so the caller never has to guess how many
        # replies are coming
        if rec.get("cmd") == "end":
            print(json.dumps({"end": True}), flush=True)
            continue
        text = (rec.get("text") or "")[:1000]
        # CONTRACT: exactly one output line per input line. Silently skipping blanks made
        # the Swift caller block forever waiting for a reply that was never coming.
        if not text.strip():
            print(json.dumps({"id": rec.get("id"), "skip": "blank"}), flush=True)
            continue
        try:
            ids = tok.encode(text, return_tensors="mlx")
            out = model(ids)
            v = out.text_embeds if hasattr(out, "text_embeds") else out[0]
            arr = to_np(v).ravel().astype(np.float32)
            n = arr / (np.linalg.norm(arr) + 1e-9)            # L2 normalize
            take = n[: a.bits]                                 # truncate to the index width
            if take.shape[0] < a.bits:                         # pad short vectors
                take = np.pad(take, (0, a.bits - take.shape[0]))
            bits = (take > 0).astype(np.uint8)                 # sign -> 1 bit
            packed = np.packbits(bits)                         # MSB-first, matches Swift
            # Tier 2: int8 rescore vectors.
            # Scale by the vector's own max component, NOT a fixed 127. `take` is
            # L2-normalized over 1024 dims, so components are ~1/sqrt(1024) ≈ 0.03 and a
            # flat 127x lands them in [-12,12] — 9% of the int8 range, throwing away
            # ~3.4 bits before the rescore has even run. Per-vector scaling is safe here
            # because the comparison is cosine, which is scale-invariant.
            mx = float(np.abs(take).max()) or 1.0
            i8 = np.clip(np.rint(take / mx * 127.0), -127, 127).astype(np.int8)
            print(json.dumps({"id": rec["id"], "bits": a.bits,
                              "hex": packed.tobytes().hex(),
                              "i8": i8.tobytes().hex()}), flush=True)
        except Exception as e:                                  # never kill the batch
            print(json.dumps({"id": rec.get("id"), "error": str(e)[:120]}), flush=True)

if __name__ == "__main__":
    main()
