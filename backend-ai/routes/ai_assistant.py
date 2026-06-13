from fastapi import APIRouter
from pydantic import BaseModel
from risk_engine import get_engine
from services.sarvam_client import generate_text, generate_tts, reverse_geocode

router = APIRouter()

# --- Pydantic Schemas ---
class ChatRequest(BaseModel):
    query: str
    lat: float
    lng: float
    language: str

class DeterrentRequest(BaseModel):
    lat: float
    lng: float
    language: str

class ChatResponse(BaseModel):
    reply: str

class DeterrentResponse(BaseModel):
    script: str
    audio_base64: str


# --- Helpers ---
def _resolve_risk(lat: float, lng: float):
    """
    Best-effort risk lookup. If the engine fails to load its datasets we still
    answer the user (Sarvam just loses the live context) instead of 500'ing.
    Returns (risk_level, explanation).
    """
    try:
        risk_data = get_engine().get_risk_score(lat, lng)
        return (
            risk_data.get("risk_level", "unknown"),
            risk_data.get("explanation", "No data available."),
        )
    except Exception as exc:
        print(f"[Chat] Risk engine unavailable (non-fatal): {exc}")
        return "unknown", "Live risk data is currently unavailable."


def _build_system_prompt(risk_level: str, explanation: str, language: str) -> str:
    """
    SENTRA is a dual-mode companion: a warm everyday assistant for women that
    ALSO has live situational awareness. It only escalates to safety mode when
    the user's message is actually about safety/danger — otherwise it just
    chats normally. The risk context is always available but never forced.
    """
    return (
        "You are SENTRA, a calm, supportive AI companion built for women's "
        "safety and everyday support. You are warm and human, never robotic.\n"
        "\n"
        "LIVE CONTEXT (use only when relevant to the user's message):\n"
        f"- The user's current area is rated {risk_level.upper()} risk.\n"
        f"- Reason: {explanation}\n"
        "\n"
        "HOW TO RESPOND:\n"
        "- If the user asks about safety, their surroundings, walking alone, "
        "feeling unsafe, or an emergency: give brief, concrete, actionable "
        "guidance and weave in the live risk context above.\n"
        "- If the user is just chatting (greetings, daily life, questions, "
        "venting): reply naturally and kindly, like a trusted friend. Do NOT "
        "force safety talk or mention risk levels when it isn't relevant.\n"
        "- Keep replies concise and easy to read on a phone under stress.\n"
        f"- Always reply in the user's language ({language}).\n"
        "- Never invent emergency-service contacts or fake facts."
    )


# --- Endpoints ---

@router.post("/chat", response_model=ChatResponse)
def safety_chat(request: ChatRequest):
    # Diagnostic: proves the request actually reached the backend. If you DON'T
    # see this line in the uvicorn terminal when you tap send, the problem is the
    # network path (wrong IP / firewall / uvicorn not on 0.0.0.0), not the AI code.
    print(f"[Chat] query={request.query!r} @ ({request.lat},{request.lng}) lang={request.language}")

    risk_level, explanation = _resolve_risk(request.lat, request.lng)
    system_prompt = _build_system_prompt(risk_level, explanation, request.language)

    reply = generate_text(request.query, system=system_prompt)
    return ChatResponse(reply=reply)


@router.post("/deterrent", response_model=DeterrentResponse)
def trigger_deterrent(request: DeterrentRequest):
    print(f"[Deterrent] @ ({request.lat},{request.lng}) lang={request.language}")

    # Reverse geocode to get the street name (guaranteed fallback inside).
    address = reverse_geocode(request.lat, request.lng)

    # Generate an authoritative one-line dispatch script.
    dispatch_system = (
        "You write short, authoritative police radio dispatch lines used as an "
        "audible deterrent. Output exactly ONE sentence, no quotes, no labels."
    )
    script_prompt = (
        f"All units, converge immediately on {address} — critical SOS in progress. "
        f"Write this as one urgent, commanding police dispatch sentence "
        f"in {request.language}."
    )
    # NOTE: keep the default (generous) max_tokens — sarvam-30b is a reasoning
    # model and a tiny budget would leave no room for the actual script.
    script = generate_text(script_prompt, system=dispatch_system)

    # The panic button must NEVER produce silence. If the LLM over-reasoned and
    # returned nothing, fall back to a deterministic English dispatch line so TTS
    # always has something authoritative to speak.
    if not script:
        print("[Deterrent] LLM returned empty script; using deterministic fallback.")
        script = (
            f"Attention all units, this is dispatch — respond immediately to "
            f"{address}, we have a critical emergency in progress, all available "
            f"officers converge now."
        )

    # Synthesize the deterrent audio (Bulbul v3).
    audio_b64 = generate_tts(script, language_code=request.language)

    return DeterrentResponse(script=script, audio_base64=audio_b64)
