# env-profiles/

`scripts/switch_model_option.sh`가 읽는 운영 모델 구성 프로파일 모음. 각 파일 하나 = 선택 가능한 구성 하나.

## 사용법
```bash
./scripts/switch_model_option.sh list          # 사용 가능한 구성 목록
./scripts/switch_model_option.sh status         # 현재 .env에 적용된 구성 확인
./scripts/switch_model_option.sh <옵션명>        # 전환(예: a, d)
```

## 새 구성 추가하는 법
이 디렉터리에 `option-<이름>.env` 파일을 하나 추가하면 끝이다(스크립트 수정 불필요).
아래 6개 키 + `LABEL`을 반드시 포함해야 한다:

```bash
LABEL="선택지 X: <사람이 읽을 설명>"
MAIN_MODEL_PATH=/models/<디렉터리명>       # ./models/<디렉터리명> 이 실제로 스테이징되어 있어야 함
MAIN_GPU_UTIL=0.XX
MAIN_MAX_LEN=NNNNN
AUTOCOMPLETE_MODEL_PATH=/models/<디렉터리명>
AUTOCOMPLETE_GPU_UTIL=0.XX
AUTOCOMPLETE_MAX_LEN=NNNN
```

`MAIN_GPU_UTIL`/`AUTOCOMPLETE_GPU_UTIL`은 이론치로 잡지 말고, §OPERATOR_GUIDE.md §10 / 완료보고서 §11.6·§13.3의
교훈대로 **반드시 순차 기동(main 먼저) 후 vLLM 로그의 `Available KV cache memory`를 보고 실측 조정**할 것.
스크립트는 안전하게 낮은 값으로 먼저 시도하다 실패하면 로그를 보여주고 중단하므로, 처음엔 보수적인 값으로
시작해도 된다.

## 현재 구성 파일
| 파일 | 구성 |
|---|---|
| `option-a.env` | 선택지 A(구) — Llama 3.3-70B **FP8** + StarCoder2-**7B** FP8, GPU 여유 ~1.4GB |
| `option-d.env` | 선택지 D(현재 채택) — Llama 3.3-70B **NVFP4** + StarCoder2-**15B** FP8, GPU 여유 ~3.5GB |

상세 비교는 `docs/VALIDATION_COMPLETION_REPORT.md` §13.9 참조.
