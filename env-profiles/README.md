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

**선택 키(미지정 시 Llama 계열 기본값으로 자동 리셋됨 — 이전 구성 값이 남지 않음):**
```bash
MAIN_SERVED_NAME=main-llama          # 기본값. main이 Llama가 아닌 다른 아키텍처면 반드시 변경(아래 참조)
MAIN_TOOL_PARSER=llama3_json         # 기본값. 모델 계열에 맞는 vLLM tool-call-parser 이름
MAIN_EXTRA_ARGS=                     # 기본 빈 문자열. --reasoning-parser 등 모델별 추가 플래그
MAIN_MXFP4_FLASHINFER=0              # 기본값. gpt-oss(MXFP4) 계열만 1
```
`MAIN_SERVED_NAME`을 Llama가 아닌 값으로 바꾸면, 전환 스크립트가 `litellm/config.yaml`의 메인 라우트
(`model_name`/`litellm_params.model`)와 클라이언트 설정(`opencode.json`의 모델 키, Continue의
`model:` 필드)까지 자동으로 함께 바꾼다 — **완전히 다른 아키텍처로 교체할 때만** 이렇게 하고, 같은
계열 내 가중치만 바꾸는 경우(예: 선택지 A↔D, 둘 다 Llama)는 `MAIN_SERVED_NAME`을 건드리지 않는다
(§13 원칙 — 클라이언트/게이트웨이 설정 변경 불필요하게 유지).

`MAIN_GPU_UTIL`/`AUTOCOMPLETE_GPU_UTIL`은 이론치로 잡지 말고, §OPERATOR_GUIDE.md §10 / 완료보고서 §11.6·§13.3의
교훈대로 **반드시 순차 기동(main 먼저) 후 vLLM 로그의 `Available KV cache memory`를 보고 실측 조정**할 것.
스크립트는 안전하게 낮은 값으로 먼저 시도하다 실패하면 로그를 보여주고 중단하므로, 처음엔 보수적인 값으로
시작해도 된다.

**단독(solo) 구성 — FIM 없이 main만 기동(예: 선택지 G):** `AUTOCOMPLETE_ENABLED=false`를 프로파일에
추가하면 `AUTOCOMPLETE_MODEL_PATH`/`AUTOCOMPLETE_GPU_UTIL`/`AUTOCOMPLETE_MAX_LEN` 세 키가 필수에서
제외되고, 전환 스크립트가 `vllm-autocomplete` 컨테이너를 아예 기동하지 않는다(해당 VRAM이 전부
main의 KV캐시로 넘어감 — 컨텍스트를 크게 확보할 수 있는 대신 IDE tab 자동완성은 그 구성이 활성인
동안 사용 불가). 이 키를 생략하면(기본값 `true`) 지금까지와 동일하게 2-트랙으로 기동한다.

## 현재 구성 파일
| 파일 | 구성 |
|---|---|
| `option-a.env` | 선택지 A(구) — Llama 3.3-70B **FP8** + StarCoder2-**7B** FP8, GPU 여유 ~1.4GB |
| `option-d.env` | 선택지 D(구) — Llama 3.3-70B **NVFP4** + StarCoder2-**15B** FP8, GPU 여유 ~3.5GB |
| `option-e.env` | 선택지 E(현재 채택, 2026-07-13~) — **gpt-oss-120b MXFP4**(다른 아키텍처) + StarCoder2-**7B** FP8, GPU 여유 ~3.7GB(컨텍스트 32768, 2026-07-14 재튜닝) |
| `option-g.env` | 선택지 G(신규, 2026-07-14~) — **gpt-oss-120b MXFP4 단독**(FIM 없음), 컨텍스트 65536, GPU 여유 ~6.05GB |

상세 비교는 `docs/VALIDATION_COMPLETION_REPORT.md` §13.9(A vs D), §17(D vs E), §18.13(G) 참조.
(※선택지 F(Llama NVFP4 단독)는 2026-07-14 실측 후 품질 미달로 당일 폐기 — §18.14 기록만 남김.)
