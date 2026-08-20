#!/usr/bin/env python3
"""
Retrieval eval with CONTROLLED ground truth.

Why this exists: the earlier ad-hoc probe defined "gold" as whichever document BM25 ranked
first for a rare term. On a corpus that is itself a transcript of building this system, that
selects *meta-commentary about the experiment* rather than a document about the topic — one
"gold" doc turned out to be a 230-char message reading "At full precision `arcminute` ranks
1 of 2015". Conclusions drawn from it (including "the rescore tier is broken") were unsound.

Here every gold pair is authored, so ground truth is known rather than inferred. Measures
Recall@k and MRR for BM25, binary-Hamming, and binary+int8-rescore over the same corpus.
"""
import json, subprocess, sys, re, math
import numpy as np

# 20 documents on distinct topics; 20 paraphrase queries sharing minimal vocabulary.
DOCS = [
 ("orrery",     "The brass planetary model drives each ring with a stepper so the bodies hold their true positions to within an arcminute for a century."),
 ("splitflap",  "Each of the thirty-six character modules snaps to its next glyph with a solenoid, and the clatter takes four seconds to settle."),
 ("hub75",      "Driving nine chained LED panels needs power injected at both ends of every row or the far corner browns out to amber."),
 ("sourdough",  "A stiff levain built at sixty percent hydration ferments slower and gives the crumb a tighter, more even structure."),
 ("bicycle",    "Indexed shifting relies on the derailleur cable having exactly the right tension, otherwise the chain hunts between sprockets."),
 ("coffee",     "Grinding finer increases extraction, so a bitter cup usually means going coarser rather than shortening the brew."),
 ("sqlitewal",  "Write-ahead logging lets readers continue while a writer appends, but a long-lived reader can starve the checkpoint forever."),
 ("popcount",   "Counting set bits after an exclusive-or is the whole distance computation, and it saturates memory bandwidth rather than compute."),
 ("spoliation", "Destroying records once litigation is anticipated draws sanctions, whereas a scheduled policy that predates the dispute does not."),
 ("gdpr",       "A camera pointed partly at the pavement stops being purely household processing, which is what the Czech doorway case decided."),
 ("tides",      "Spring tides arrive when sun and moon pull along the same axis, roughly twice each lunar month."),
 ("bread",      "Steam in the first ten minutes keeps the crust soft enough for the loaf to spring before it sets."),
 ("knots",      "A bowline holds a fixed loop that will not slip under load yet unties easily once the tension comes off."),
 ("solder",     "Cold joints look dull and grainy; reheating with a little flux and fresh alloy usually fixes them."),
 ("sleep",      "Slow-wave periods replay the day's experience and strengthen what overlaps, while the rest decays."),
 ("ferns",      "Bracken spreads through underground rhizomes, which is why cutting the visible fronds achieves so little."),
 ("lenses",     "A longer focal length compresses apparent distance between foreground and background subjects."),
 ("tea",        "Green leaves scorch above eighty degrees, turning the liquor harsh and grassy."),
 ("concrete",   "Curing slowly under damp cover develops far more strength than letting the surface dry in the sun."),
 ("birds",      "Corvids cache food in scattered sites and return to them months later with startling accuracy."),
]
QUERIES = [
 ("orrery",     "how precise is the clockwork model of the planets"),
 ("splitflap",  "the display whose letters flip over with a mechanical noise"),
 ("hub75",      "why does the far end of my led wall look dim and orange"),
 ("sourdough",  "does a drier starter change the texture of the loaf"),
 ("bicycle",    "my gears keep skipping between cogs"),
 ("coffee",     "my espresso tastes too bitter what should I change"),
 ("sqlitewal",  "an open read transaction stops the database log from being trimmed"),
 ("popcount",   "measuring how quickly binary distance comparisons run"),
 ("spoliation", "deleting records after a lawsuit begins is a problem"),
 ("gdpr",       "filming beyond your own property loses the domestic exemption"),
 ("tides",      "when is the water highest because of the moon and sun aligning"),
 ("bread",      "keeping moisture in the oven early so the loaf rises"),
 ("knots",      "a loop that stays put but comes undone without a fight"),
 ("solder",     "the joint looks grey and rough what went wrong"),
 ("sleep",      "how does rest consolidate what you learned during the day"),
 ("ferns",      "the plant keeps returning because of its root system"),
 ("lenses",     "which lens makes the background look closer to the subject"),
 ("tea",        "water too hot makes the drink taste bitter and vegetal"),
 ("concrete",   "keeping it damp while it hardens makes it stronger"),
 ("birds",      "these animals remember where they hid things for months"),
]

def embed(texts, bits):
    # the sidecar batches, so a partial batch only flushes on the end marker
    inp = "\n".join(json.dumps({"id": i, "text": t}) for i, t in enumerate(texts))
    inp += "\n" + json.dumps({"cmd": "end"})
    out = subprocess.run(["python3", "tools/embed_qwen3.py", "--bits", str(bits)],
                         input=inp, capture_output=True, text=True).stdout
    B, I = {}, {}
    for l in out.strip().split("\n"):
        if not l.strip(): continue
        o = json.loads(l)
        if "hex" not in o: continue
        B[o["id"]] = np.unpackbits(np.frombuffer(bytes.fromhex(o["hex"]), dtype=np.uint8))
        I[o["id"]] = np.frombuffer(bytes.fromhex(o["i8"]), dtype=np.int8).astype(np.float32)
    return ([B[i] for i in range(len(texts))], [I[i] for i in range(len(texts))])

def bm25_rank(qtext, docs):
    # crude but honest lexical baseline: idf-weighted term overlap
    tok = lambda s: re.findall(r"[a-z]+", s.lower())
    D = [tok(d) for _, d in docs]
    N = len(D)
    df = {}
    for d in D:
        for w in set(d): df[w] = df.get(w, 0) + 1
    scores = []
    for i, d in enumerate(D):
        s = 0.0
        for w in tok(qtext):
            if w in d and w in df:
                s += math.log(1 + N / df[w])
        scores.append((i, s))
    return [i for i, s in sorted(scores, key=lambda x: -x[1])]

def main():
    bits = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    texts = [d for _, d in DOCS]
    dB, dI = embed(texts, bits)
    qB, qI = embed([q for _, q in QUERIES], bits)
    keys = [k for k, _ in DOCS]
    DBm = np.stack(dB); DIm = np.stack(dI)
    DIn = DIm / (np.linalg.norm(DIm, axis=1, keepdims=True) + 1e-9)

    res = {m: {"r1": 0, "r5": 0, "mrr": 0.0} for m in ("bm25", "binary", "rescore")}
    SHORT = 8   # binary shortlist size fed to the rescore
    for qi, (gold, qtext) in enumerate(QUERIES):
        g = keys.index(gold)
        ranks = {}
        ranks["bm25"] = bm25_rank(qtext, DOCS)
        ham = np.count_nonzero(DBm != qB[qi], axis=1)
        ranks["binary"] = list(np.argsort(ham))
        short = ranks["binary"][:SHORT]
        qn = qI[qi] / (np.linalg.norm(qI[qi]) + 1e-9)
        cos = {c: float(DIn[c] @ qn) for c in short}
        ranks["rescore"] = sorted(short, key=lambda c: -cos[c]) + \
                           [c for c in ranks["binary"] if c not in short]
        for m, order in ranks.items():
            r = order.index(g) + 1
            res[m]["r1"] += (r == 1); res[m]["r5"] += (r <= 5); res[m]["mrr"] += 1.0 / r

    n = len(QUERIES)
    print(f"  corpus: {len(DOCS)} authored docs · {n} paraphrase queries · {bits}-bit\n")
    print(f"  {'method':10} {'Recall@1':>9} {'Recall@5':>9} {'MRR':>7}")
    print("  " + "-" * 38)
    for m in ("bm25", "binary", "rescore"):
        d = res[m]
        print(f"  {m:10} {d['r1']/n:>9.2f} {d['r5']/n:>9.2f} {d['mrr']/n:>7.3f}")

if __name__ == "__main__":
    main()
