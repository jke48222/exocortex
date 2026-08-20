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


def quantize(vec, bits):
    """L2-normalize, truncate to the index width, then emit both tiers."""
    n = vec / (np.linalg.norm(vec) + 1e-9)
    take = n[:bits]
    if take.shape[0] < bits:
        take = np.pad(take, (0, bits - take.shape[0]))
    packed = np.packbits((take > 0).astype(np.uint8))          # 1 bit/dim, MSB-first
    # int8 rescore tier, scaled by the vector's own max component rather than a flat
    # 127x: L2-normalizing 1024 dims leaves components near 0.03, so a fixed scale lands
    # them in [-12,12] and throws away ~3.4 bits before the rescore even runs. Safe
    # because the comparison is cosine, which is scale-invariant.
    mx_ = float(np.abs(take).max()) or 1.0
    i8 = np.clip(np.rint(take / mx_ * 127.0), -127, 127).astype(np.int8)
    return packed.tobytes().hex(), i8.tobytes().hex()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=256)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--maxlen", type=int, default=512)
    a = ap.parse_args()

    model, tok = load(a.model)
    print(json.dumps({"ready": True, "model": a.model, "bits": a.bits, "batch": a.batch}),
          file=sys.stderr, flush=True)

    pending = []          # list of (id, text_or_None) preserving input order

    def flush():
        """One forward pass for the whole batch, then emit one line per input IN ORDER.

        The first version ran a forward pass per chunk, which measured 0.92 vectors/s —
        about 76 hours for a 91k-event corpus. For a 0.6B model the arithmetic is not the
        cost; Python round-trips and MLX graph evaluation are, and batching amortizes both.
        """
        nonlocal pending
        if not pending:
            return
        idxs = [k for k, (_, t) in enumerate(pending) if t]
        results = {}
        if idxs:
            texts = [pending[k][1] for k in idxs]
            try:
                enc = tok._tokenizer(texts, padding=True, truncation=True,
                                     max_length=a.maxlen, return_tensors="mlx")
                out = model(enc["input_ids"], attention_mask=enc["attention_mask"])
                emb = to_np(out.text_embeds)          # (N, D)
                for row, k in enumerate(idxs):
                    results[k] = quantize(emb[row], a.bits)
            except Exception as e:                     # never lose a whole batch
                for k in idxs:
                    results[k] = None
                print(json.dumps({"batch_error": str(e)[:160]}), file=sys.stderr, flush=True)
        for k, (rid, _) in enumerate(pending):
            r = results.get(k)
            if r is None:
                print(json.dumps({"id": rid, "skip": "blank_or_error"}), flush=True)
            else:
                print(json.dumps({"id": rid, "bits": a.bits, "hex": r[0], "i8": r[1]}), flush=True)
        pending = []

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            print(json.dumps({"id": None, "skip": "badjson"}), flush=True)
            continue
        # explicit end-of-batch marker: flush, then acknowledge, so the reader never has
        # to guess how many replies are coming
        if rec.get("cmd") == "end":
            flush()
            print(json.dumps({"end": True}), flush=True)
            continue
        text = (rec.get("text") or "")[:2000]
        pending.append((rec.get("id"), text.strip() or None))
        if len(pending) >= a.batch:
            flush()


if __name__ == "__main__":
    main()
