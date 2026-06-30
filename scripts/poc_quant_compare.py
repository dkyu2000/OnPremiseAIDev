#!/usr/bin/env python3
"""scripts/poc_quant_compare.py — 양자화/모델 크기 품질·속도 비교 PoC

같은 프롬프트셋을 OpenAI 호환 엔드포인트(vLLM)로 보내 응답 품질(육안 비교용 출력)과
디코드 throughput(tok/s), 지연(latency)을 측정한다.

사용:
  python3 poc_quant_compare.py <엔드포인트URL> <표시이름>
  예) python3 poc_quant_compare.py http://localhost:8000 "Llama-8B-FP8"

결과를 동일 포맷으로 출력하므로, 세 모델을 차례로 띄워가며 실행해 표로 비교한다.
"""
import sys, time, json, urllib.request

URL = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:8000"
NAME = sys.argv[2] if len(sys.argv) > 2 else "model"

# 기본 프롬프트셋 (정답 명확)
PROMPTS_EASY = [
    ("코드생성", "Write a Python function `is_prime(n)` that returns True if n is prime. Code only.", "정상 소수 판정"),
    ("알고리즘추론", "A train travels 60 km in 45 minutes. What is its average speed in km/h? Show the calculation.", "80 km/h"),
    ("한국어요약", "다음을 한 문장으로 요약: 양자컴퓨터는 큐비트를 사용해 중첩과 얽힘으로 특정 문제를 고전 컴퓨터보다 빠르게 푼다.", "핵심 보존 요약"),
    ("사실성", "List exactly three programming languages that run on the JVM. Just the names.", "Java/Kotlin/Scala/Groovy 중 3개"),
    ("지시따르기", "Reply with exactly the word: ACKNOWLEDGED", "ACKNOWLEDGED"),
]

# ★까다로운 프롬프트셋 — 함정/엣지케이스/논리오류/엄격포맷 (작은모델이 틀리기 쉬움)
PROMPTS_HARD = [
    ("함정추론", "If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets? Answer with just the number and unit.", "정답: 5분 (대당 처리율 불변)"),
    ("역산수학", "A shirt now costs $48 after a 20% discount. What was the original price? Show steps.", "정답: $60 (48/0.8)"),
    ("논리오류지적", "이 삼단논법의 오류를 한 문장으로 지적하라: '모든 새는 난다. 펭귄은 새다. 따라서 펭귄은 난다.'", "정답: 대전제('모든 새는 난다')가 거짓"),
    ("엣지케이스코딩", "Write Python `def median(nums)` returning the median of a list. Must handle empty list and even-length list correctly. Code only.", "빈 리스트 처리 + 짝수길이 평균"),
    ("엄격포맷", "Output ONLY a valid JSON object with keys \"name\"(string) and \"age\"(int) for Kim aged 30. No markdown, no code fence, no extra text.", '정답: {"name":"Kim","age":30} (펜스/설명 없이)'),
    ("다단계추론", "Sally has 3 brothers. Each brother has 2 sisters. How many sisters does Sally have? Explain.", "정답: 1명 (Sally 본인 제외, 자매는 Sally 포함 2명이므로 Sally의 자매는 1명)"),
    ("한국어함정", "한 농부가 닭과 토끼를 키운다. 머리가 총 10개, 다리가 총 28개다. 토끼는 몇 마리인가? 풀이 포함.", "정답: 토끼 4마리, 닭 6마리"),
]
MAX_TOKENS = 320  # 까다로운 문제는 풀이 공간 필요

def call(prompt):
    body = json.dumps({
        "model": "x",  # vLLM 단일 모델 서빙이라 무시됨 (served-model-name 자동)
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS, "temperature": 0,
    }).encode()
    # 모델명을 서버에서 받아 사용
    req = urllib.request.Request(URL + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.loads(urllib.request.urlopen(req, timeout=120).read())
    dt = time.time() - t0
    u = r["usage"]
    return dt, u["completion_tokens"], r["choices"][0]["message"]["content"]

def served_model():
    try:
        r = json.loads(urllib.request.urlopen(URL + "/v1/models", timeout=10).read())
        return r["data"][0]["id"]
    except Exception:
        return "?"

def main():
    mode = sys.argv[3] if len(sys.argv) > 3 else "easy"
    prompts = PROMPTS_HARD if mode == "hard" else PROMPTS_EASY
    model_id = served_model()
    print(f"\n{'='*72}\n▶ {NAME}  [{mode}]  (served: {model_id} @ {URL})\n{'='*72}")
    try:
        warm = json.dumps({"model": model_id, "messages":[{"role":"user","content":"hi"}], "max_tokens":4}).encode()
        urllib.request.urlopen(urllib.request.Request(URL+"/v1/chat/completions", data=warm, headers={"Content-Type":"application/json"}), timeout=60)
    except Exception as e:
        print("  워밍업 실패:", e); return

    tot_tok, tot_dt = 0, 0.0
    for label, p, expect in prompts:
        body = json.dumps({"model": model_id, "messages":[{"role":"user","content":p}], "max_tokens":MAX_TOKENS, "temperature":0}).encode()
        t0 = time.time()
        r = json.loads(urllib.request.urlopen(urllib.request.Request(URL+"/v1/chat/completions", data=body, headers={"Content-Type":"application/json"}), timeout=120).read())
        dt = time.time()-t0
        out = r["choices"][0]["message"]["content"].strip()
        n = r["usage"]["completion_tokens"]
        tot_tok += n; tot_dt += dt
        print(f"\n[{label}]  (기대: {expect})  · {n}tok/{dt:.2f}s")
        # 까다로운 셋은 전문 출력(짧게 자르지 않음 — 채점용)
        for line in out.split("\n"):
            print(f"  | {line}")
    print(f"\n── {NAME} 종합: 평균 throughput {tot_tok/tot_dt:.1f} tok/s (총 {tot_tok}tok / {tot_dt:.2f}s) ──")

if __name__ == "__main__":
    main()
