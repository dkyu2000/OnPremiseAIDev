"""
litellm/gemma_compat.py — Gemma 2 호환 게이트웨이 변환 (LiteLLM pre-call hook)

★[2026-07-07 비활성] 서브 채팅 모델(sub-gemma, prod-gemma27b)을 운영에서 쓰지 않기로 확정하면서
  litellm/config.yaml의 callbacks 목록과 docker-compose.yml의 volumes 마운트에서 제외했다.
  현재 이 파일은 어디서도 로드되지 않는다(비활성). Phase B/C 역사적 검증에서 실제로 문제를 해결한
  코드라 참고용으로 보존한다 — Gemma 트랙을 재검토할 경우 config.yaml/docker-compose.yml에
  다시 연결하면 된다(git 이력 참조).

배경:
  Gemma 2 chat template 은 ① system role 거부(raise_exception 'System role not supported'),
  ② tools/function 미지원이다. 그래서 OpenCode 등 에이전트 클라이언트(system prompt + tools 사용)가
  sub-gemma / prod-gemma27b 를 호출하면 vLLM 이 거부한다.

이 훅의 역할 (model 명에 'gemma' 포함 시에만):
  - tools / tool_choice / functions / function_call 파라미터 제거 (도구 호출 비활성)
  - system 메시지를 바로 뒤 첫 user 메시지 앞에 병합(없으면 user 로 승격) → system role 제거
  - 연속된 동일 role 을 병합하여 Gemma 의 user/assistant 교대 제약 충족

효과:
  OpenCode 에서 Gemma 를 선택해도 '채팅/질의응답' 은 정상 동작한다.
  단, 도구 실행(파일 편집·명령)은 Gemma 가 구조적으로 못 한다(에이전트 작업은 main-llama 사용).

연동:
  - litellm/config.yaml → litellm_settings.callbacks 에 "gemma_compat.gemma_compat_handler" 추가
  - docker-compose.yml → litellm.volumes 에 ./litellm/gemma_compat.py 마운트
"""

import logging
from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("gemma_compat")

# 제거할 도구 관련 파라미터 (Gemma 미지원)
_TOOL_KEYS = ("tools", "tool_choice", "functions", "function_call", "parallel_tool_calls")


def _content_to_text(content):
    """OpenAI content (str 또는 멀티모달 block 리스트)를 평문으로."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                parts.append(b.get("text") or b.get("content") or "")
            else:
                parts.append(str(b))
        return "\n".join(p for p in parts if p)
    return "" if content is None else str(content)


def _transform_messages(messages):
    """system 병합 + 연속 동일 role 병합 → Gemma(user/assistant 교대, system 불가) 호환."""
    pending_system = ""
    merged = []
    for m in messages:
        role = m.get("role")
        text = _content_to_text(m.get("content"))
        if role == "system":
            pending_system = (pending_system + "\n\n" + text) if pending_system else text
            continue
        if role == "user" and pending_system:
            text = pending_system + "\n\n" + text
            pending_system = ""
        # 연속 동일 role 병합
        if merged and merged[-1]["role"] == role:
            merged[-1]["content"] = merged[-1]["content"] + "\n\n" + text
        else:
            merged.append({"role": role, "content": text})
    # system 만 있고 뒤따르는 user 가 없던 경우 → user 로 승격
    if pending_system:
        if merged and merged[0]["role"] == "user":
            merged[0]["content"] = pending_system + "\n\n" + merged[0]["content"]
        else:
            merged.insert(0, {"role": "user", "content": pending_system})
    return merged


class GemmaCompat(CustomLogger):
    """Gemma 2 요청을 vLLM 전송 전에 호환 변환하는 pre-call hook."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            model = (data.get("model") or "").lower()
            if "gemma" not in model:
                return data
            # 도구 파라미터 제거
            for k in _TOOL_KEYS:
                data.pop(k, None)
            # system 병합 + 교대 정리
            msgs = data.get("messages")
            if msgs:
                data["messages"] = _transform_messages(msgs)
            logger.info("gemma_compat: '%s' 요청 변환(tools 제거 + system 병합)", model)
        except Exception as e:  # 변환 실패가 요청을 막지 않도록 흡수
            logger.warning("gemma_compat: 변환 실패(원본 유지): %s", e)
        return data


# config.yaml callbacks 가 참조하는 인스턴스
gemma_compat_handler = GemmaCompat()
