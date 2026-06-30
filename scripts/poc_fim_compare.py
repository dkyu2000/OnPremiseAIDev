#!/usr/bin/env python3
"""scripts/poc_fim_compare.py — FIM 자동완성 품질 비교 PoC (StarCoder2 vs Qwen2.5-Coder)

코드 자동완성(FIM)을 prefix+suffix 로 호출해 "중간을 정확히 채우는가"를 본다.
정답이 명확한 케이스로 육안 채점 + throughput 측정.

사용:
  python3 poc_fim_compare.py <엔드포인트URL> <표시이름> <fim포맷: starcoder|qwen>
  예) python3 poc_fim_compare.py http://localhost:8003 "StarCoder2-7B" starcoder
      python3 poc_fim_compare.py http://localhost:8004 "Qwen2.5-Coder-7B" qwen

엔드포인트는 각 모델을 단독 기동한 vLLM(/v1/completions).
"""
import sys, time, json, urllib.request

URL = sys.argv[1].rstrip("/")
NAME = sys.argv[2] if len(sys.argv) > 2 else "model"
FMT = sys.argv[3] if len(sys.argv) > 3 else "starcoder"

# FIM 특수 토큰 (모델별)
FIM = {
    "starcoder": ("<fim_prefix>", "<fim_suffix>", "<fim_middle>", ["<|endoftext|>", "<file_sep>"]),
    "qwen":      ("<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>"]),
}
PRE, SUF, MID, STOPS = FIM[FMT]

# (라벨, prefix, suffix, 기대답안) — 중간(MID)에 와야 할 코드
CASES = [
    ("이진탐색",
     "def binary_search(arr, target):\n    lo, hi = 0, len(arr) - 1\n    while lo <= hi:\n        mid = (lo + hi) // 2\n        ",
     "\n    return -1\n",
     "if arr[mid]==target: return mid; elif <: lo=mid+1; else hi=mid-1"),
    ("엣지케이스 median",
     "def median(nums):\n    if not nums:\n        return None\n    s = sorted(nums)\n    n = len(s)\n    ",
     "\n",
     "짝수/홀수 분기 (n%2) 평균 처리"),
    ("재귀 팩토리얼",
     "def factorial(n):\n    if n <= 1:\n        return 1\n    ",
     "\n",
     "return n * factorial(n-1)"),
    ("dict 컴프리헨션",
     "# 1~5 의 제곱을 담은 딕셔너리\nsquares = ",
     "\nprint(squares)\n",
     "{x: x**2 for x in range(1,6)}"),
    ("예외처리",
     "def safe_div(a, b):\n    try:\n        return a / b\n    ",
     "\n",
     "except ZeroDivisionError: return None"),
    ("클래스 메서드",
     "class Stack:\n    def __init__(self):\n        self.items = []\n    def push(self, x):\n        self.items.append(x)\n    def pop(self):\n        ",
     "\n",
     "빈 스택 처리 + return self.items.pop()"),
]
MAX_TOKENS = 80

def model_id():
    try:
        r = json.loads(urllib.request.urlopen(URL + "/v1/models", timeout=10).read())
        return r["data"][0]["id"]
    except Exception:
        return "x"

def main():
    mid = model_id()
    print(f"\n{'='*72}\n▶ {NAME}  [{FMT} FIM]  (served: {mid} @ {URL})\n{'='*72}")
    tot_tok, tot_dt = 0, 0.0
    for label, pre, suf, expect in CASES:
        prompt = f"{PRE}{pre}{SUF}{suf}{MID}"
        body = json.dumps({"model": mid, "prompt": prompt, "max_tokens": MAX_TOKENS,
                           "temperature": 0, "stop": STOPS}).encode()
        t0 = time.time()
        try:
            r = json.loads(urllib.request.urlopen(urllib.request.Request(
                URL + "/v1/completions", data=body, headers={"Content-Type": "application/json"}), timeout=60).read())
            dt = time.time() - t0
            out = r["choices"][0]["text"]
            n = r["usage"]["completion_tokens"]
            tot_tok += n; tot_dt += dt
            print(f"\n[{label}]  (기대: {expect})  · {n}tok/{dt:.2f}s")
            for line in out.split("\n"):
                print(f"  | {line}")
        except Exception as e:
            print(f"\n[{label}] 오류: {e}")
    if tot_dt:
        print(f"\n── {NAME} 종합: 평균 throughput {tot_tok/tot_dt:.1f} tok/s ──")

if __name__ == "__main__":
    main()
