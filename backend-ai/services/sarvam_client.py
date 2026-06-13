"""
Thin, well-typed wrapper around the Sarvam AI REST API.

All raw HTTP lives here so the route layer (routes/ai_assistant.py) stays clean.
Specs verified against https://docs.sarvam.ai (chat completions + TTS bulbul:v3).

Auth: Sarvam accepts the subscription key (sk_...) via either
`Authorization: Bearer <key>` or `api-subscription-key: <key>`. We use the
latter uniformly because the same header works for every endpoint.
"""
import os
import requests
from fastapi import HTTPException

# --- Endpoints ---------------------------------------------------------------
_BASE = "https://api.sarvam.ai"
_CHAT_URL = f"{_BASE}/v1/chat/completions"
_TTS_URL = f"{_BASE}/text-to-speech"

# --- Tunables (overridable via env) ------------------------------------------
# sarvam-30b (64K ctx) is the balanced production model; sarvam-105b is the
# flagship but reasons much longer (latency spikes to ~20s). sarvam-m is now
# deprecated and rejected by the API. Default to 30b: faster and more consistent.
# NOTE: use `or default`, not get(key, default). A blank line in .env
# (SARVAM_CHAT_MODEL=) sets the var to "" — which get() would NOT replace with
# the default, sending an empty model and 400'ing every request.
_CHAT_MODEL = os.environ.get("SARVAM_CHAT_MODEL") or "sarvam-30b"
# bulbul:v3 voice. NOTE: v1/v2 voices (meera, anushka, vidya...) are INVALID for
# v3. Valid v3 speakers include: aditya, ritu, priya, neha, rahul, rohan, ratan,
# varun, vijay, kabir, shubh, niharika, ... "vijay" is an authoritative voice,
# well suited to the fake police-dispatch deterrent.
_TTS_SPEAKER = os.environ.get("SARVAM_TTS_SPEAKER") or "vijay"
_TTS_MODEL = "bulbul:v3"

# bulbul:v3 only supports these target languages. Anything else 400s, so we
# fall back to en-IN to keep the deterrent from ever failing on a bad code.
_TTS_SUPPORTED_LANGS = {
    "bn-IN", "en-IN", "gu-IN", "hi-IN", "kn-IN", "ml-IN",
    "mr-IN", "od-IN", "pa-IN", "ta-IN", "te-IN",
}

# Hard cap on output tokens. The API rejects anything above the subscription
# tier limit (starter tier for sarvam-30b = 4096) with a 400. We request the
# full ceiling so the reasoning phase has maximum room to still reach an answer.
_MAX_OUTPUT_TOKENS = int(os.environ.get("SARVAM_MAX_TOKENS") or "4096")

# (connect, read) timeouts in seconds. Without these, `requests` blocks
# FOREVER on a stalled connection — which is exactly what made the chat hang
# for a full minute until the Flutter client's own 60s timeout fired.
_CONNECT_TIMEOUT = 5
_LLM_READ_TIMEOUT = 45  # 30b answers in ~5-7s; headroom for occasional spikes
_TTS_READ_TIMEOUT = 30


def _headers() -> dict:
    return {
        "Content-Type": "application/json",
        "api-subscription-key": os.environ.get("SARVAM_API_KEY", ""),
    }


def generate_text(
    prompt: str,
    *,
    system: str | None = None,
    max_tokens: int = _MAX_OUTPUT_TOKENS,
    temperature: float = 0.3,
) -> str:
    """
    Call the Sarvam chat-completions LLM and return the assistant's text.

    IMPORTANT — two hard-won facts about sarvam-30b / sarvam-105b:
      1. They are REASONING models: they emit an internal chain-of-thought into
         `reasoning_content` and only then write the user-facing answer into
         `content`. If `max_tokens` is too small the thinking eats the whole
         budget (finish_reason="length") and `content` comes back null. Hence
         we request the full tier ceiling (4096) and retry once if the answer is
         still empty — see the loop below.
      2. Do NOT pass `reasoning_effort`: setting it (even "low") forces longer,
         unbounded thinking that starves the answer. Omitting it lets the model
         answer in ~5-7s on sarvam-30b.

    Raises HTTPException(502) on any API/network failure so the route can
    translate it into a clean client error instead of a silent hang.
    """
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    # Reasoning length is variable: occasionally it exceeds the budget and starves
    # the answer (finish_reason="length", content=null). We can't raise the budget
    # past the tier cap, so retry once at the SAME (capped) budget — with temp>0 the
    # next sample usually reasons less and lands an answer.
    budget = min(max_tokens, _MAX_OUTPUT_TOKENS)
    attempts = 2
    for attempt in range(attempts):
        payload = {
            "model": _CHAT_MODEL,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": budget,
        }
        try:
            response = requests.post(
                _CHAT_URL,
                headers=_headers(),
                json=payload,
                timeout=(_CONNECT_TIMEOUT, _LLM_READ_TIMEOUT),
            )
            response.raise_for_status()
            data = response.json()
            choice = (data.get("choices") or [{}])[0]
            content = ((choice.get("message") or {}).get("content") or "").strip()
            if content:
                return content
            print(
                f"[Sarvam LLM] empty content (finish_reason="
                f"{choice.get('finish_reason')}, budget={budget}); "
                f"{'retrying' if attempt < attempts - 1 else 'giving up'}."
            )
        except requests.exceptions.RequestException as e:
            print(f"[Sarvam LLM Error] {e}")
            if getattr(e, "response", None) is not None:
                print(f"[Sarvam LLM Response] {e.response.text}")
            raise HTTPException(status_code=502, detail=f"Sarvam LLM API Error: {e}")

    return ""  # all attempts reasoned past the budget — caller decides fallback


def generate_tts(text: str, language_code: str = "hi-IN") -> str:
    """
    Synthesize `text` with Bulbul v3 and return a base64 WAV string.

    v3 takes a single `text` field (NOT the v2 `inputs` array) and only the
    languages in `_TTS_SUPPORTED_LANGS`; unsupported codes fall back to en-IN.
    """
    text = (text or "").strip()
    if not text:
        # Never hit the API with empty text (it 400s); let the caller fall back.
        raise HTTPException(status_code=502, detail="TTS called with empty text.")

    lang = language_code if language_code in _TTS_SUPPORTED_LANGS else "en-IN"

    payload = {
        "text": text[:2500],  # bulbul:v3 hard limit is 2500 chars
        "target_language_code": lang,
        "model": _TTS_MODEL,
        "speaker": _TTS_SPEAKER,
        "pace": 1.0,
        "speech_sample_rate": 22050,  # high quality for a full-volume deterrent
        "enable_preprocessing": True,
    }

    try:
        response = requests.post(
            _TTS_URL,
            headers=_headers(),
            json=payload,
            timeout=(_CONNECT_TIMEOUT, _TTS_READ_TIMEOUT),
        )
        response.raise_for_status()
        data = response.json()
        audios = data.get("audios")
        if isinstance(audios, list) and audios:
            return audios[0]
        return data.get("base64", "")
    except requests.exceptions.RequestException as e:
        print(f"[Sarvam TTS Error] {e}")
        if getattr(e, "response", None) is not None:
            print(f"[Sarvam TTS Response] {e.response.text}")
        raise HTTPException(status_code=502, detail=f"Sarvam TTS API Error: {e}")


def reverse_geocode(lat: float, lng: float) -> str:
    """
    Resolve lat/lng to a human street address via Mapbox.
    Best-effort: any failure falls back to "this location" so the deterrent
    script can still be generated.
    """
    token = os.environ.get("MAPBOX_ACCESS_TOKEN", "")
    url = (
        "https://api.mapbox.com/search/geocode/v6/reverse"
        f"?longitude={lng}&latitude={lat}&access_token={token}"
    )
    try:
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        features = response.json().get("features", [])
        if features:
            return features[0].get("properties", {}).get("full_address", "this location")
        return "this location"
    except requests.exceptions.RequestException:
        return "this location"
