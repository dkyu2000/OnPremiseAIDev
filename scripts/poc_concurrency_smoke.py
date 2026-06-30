#!/usr/bin/env python3
"""scripts/poc_concurrency_smoke.py — B-3 소규모 동시성 스모크 (TEST_PLAN B-3)

LiteLLM(4000) 게이트웨이로 main/sub 모델에 동시 요청을 보내, 분배·KV 캐시 안정성을 본다.
가벼운 부하만(50인 풀로드는 운영 장비). 동시 N개를 여러 라운드 반복.

사용:
  python3 poc_concurrency_smoke.py <가상키> [동시수=8] [라운드=3]
"""
import sys, time, json, threading, urllib.request

KEY = sys.argv[1]
CONCURRENCY = int(sys.argv[2]) if len(sys.argv) > 2 else 8
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 3
BASE = "http://localhost:4000"

# main/sub 를 섞어 요청 (분배 검증). 작업 유형도 섞음.
TASKS = [
    ("main-llama", "Explain quicksort in two sentences."),
    ("sub-gemma", "2 더하기 3은?"),
    ("main-llama", "Write a one-line Python list comprehension for squares of 1..5."),
    ("sub-gemma", "What color is the sky? One word."),
    ("main-llama", "Summarize TCP in one sentence."),
    ("sub-gemma", "파이썬에서 리스트 길이 구하는 함수?"),
    ("main-llama", "Name three sorting algorithms."),
    ("sub-gemma", "1부터 5까지 더하면?"),
]

results = []  # (model, ok, latency, tokens, err)
lock = threading.Lock()

def one_call(idx):
    model, prompt = TASKS[idx % len(TASKS)]
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": 64, "temperature": 0}).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    t0 = time.time()
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=60).read())
        dt = time.time() - t0
        served = r.get("model")
        tok = r.get("usage", {}).get("completion_tokens", 0)
        content = r["choices"][0]["message"]["content"]
        ok = bool(content and content.strip())
        with lock:
            results.append((served, ok, dt, tok, None))
    except Exception as e:
        with lock:
            results.append((model, False, time.time() - t0, 0, str(e)[:60]))

def main():
    print(f"동시성 스모크: 동시 {CONCURRENCY} × {ROUNDS}라운드 = {CONCURRENCY*ROUNDS}건 (main/sub 혼합)\n")
    t_all = time.time()
    for rnd in range(ROUNDS):
        threads = [threading.Thread(target=one_call, args=(rnd * CONCURRENCY + i,)) for i in range(CONCURRENCY)]
        rt0 = time.time()
        for t in threads: t.start()
        for t in threads: t.join()
        print(f"  라운드 {rnd+1}: {CONCURRENCY}건 완료 ({time.time()-rt0:.2f}s)")
    total_dt = time.time() - t_all

    ok = sum(1 for r in results if r[1])
    n = len(results)
    by_model = {}
    lat = [r[2] for r in results if r[1]]
    for served, success, dt, tok, err in results:
        by_model.setdefault(served, {"ok": 0, "fail": 0})
        by_model[served]["ok" if success else "fail"] += 1
    errs = [r[4] for r in results if not r[1] and r[4]]

    print(f"\n{'='*56}")
    print(f"결과: {ok}/{n} 성공 ({100*ok/n:.0f}%)  | 총 {total_dt:.2f}s")
    print(f"모델별 분배:")
    for m, c in sorted(by_model.items(), key=lambda x: str(x[0])):
        print(f"  - {m}: 성공 {c['ok']} / 실패 {c['fail']}")
    if lat:
        lat.sort()
        print(f"지연(성공): 평균 {sum(lat)/len(lat):.2f}s | p50 {lat[len(lat)//2]:.2f}s | max {lat[-1]:.2f}s")
    if errs:
        print(f"오류 샘플: {errs[:3]}")
    print(f"{'='*56}")
    print("✔ KV 캐시 안정(OOM/오류 없음)" if ok == n else "⚠ 일부 실패 — 로그 확인 필요")

if __name__ == "__main__":
    main()
