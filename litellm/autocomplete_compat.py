"""
litellm/autocomplete_compat.py — 자동완성 FIM 토큰 호환 변환 (LiteLLM pre-call hook)

배경:
  Continue 등 IDE 자동완성 클라이언트는 FIM 토큰 형식을 모델별로 자동 추론하는데,
  커스텀 모델명(autocomplete-qwen)을 Qwen 으로 인식 못해 StarCoder2 형식 토큰
  (<fim_prefix>/<fim_suffix>/<fim_middle>)을 보낸다. Qwen2.5-Coder 는 <|fim_prefix|>… 형식이라
  토큰 불일치로 빈 응답(0 tok)을 낸다.

이 훅의 역할 (model 명에 'qwen' 포함 시에만):
  - completion 의 prompt 또는 chat 의 messages 내 StarCoder2 FIM 토큰을 Qwen 형식으로 치환.
    <fim_prefix>  → <|fim_prefix|>
    <fim_suffix>  → <|fim_suffix|>
    <fim_middle>  → <|fim_middle|>

연동:
  - litellm/config.yaml → litellm_settings.callbacks 에 "autocomplete_compat.autocomplete_compat_handler"
  - docker-compose.yml → litellm.volumes 에 ./litellm/autocomplete_compat.py 마운트
"""

import logging
from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("autocomplete_compat")

_REPL = (
    ("<fim_prefix>", "<|fim_prefix|>"),
    ("<fim_suffix>", "<|fim_suffix|>"),
    ("<fim_middle>", "<|fim_middle|>"),
)


def _to_qwen_fim(text):
    if not isinstance(text, str):
        return text
    for a, b in _REPL:
        if a in text:
            text = text.replace(a, b)
    return text


class AutocompleteCompat(CustomLogger):
    """Qwen 자동완성 요청의 FIM 토큰을 Qwen 형식으로 정규화."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            model = (data.get("model") or "").lower()
            if "qwen" not in model:
                return data
            # completion: prompt(str 또는 list)
            if "prompt" in data and data["prompt"] is not None:
                p = data["prompt"]
                data["prompt"] = [_to_qwen_fim(x) for x in p] if isinstance(p, list) else _to_qwen_fim(p)
            # chat: messages[].content (일부 클라이언트가 FIM 을 chat 으로 보내는 경우)
            if data.get("messages"):
                for m in data["messages"]:
                    if isinstance(m.get("content"), str):
                        m["content"] = _to_qwen_fim(m["content"])
        except Exception as e:  # 변환 실패가 요청을 막지 않도록 흡수
            logger.warning("autocomplete_compat: 변환 실패(원본 유지): %s", e)
        return data


# config.yaml callbacks 가 참조하는 인스턴스
autocomplete_compat_handler = AutocompleteCompat()
