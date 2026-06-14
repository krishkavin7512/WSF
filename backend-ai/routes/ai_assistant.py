from datetime import datetime

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
def _hour_descriptor(hour: int) -> str:
    """Map a 24h hour to a plain-language part of day for the LLM context."""
    if 0 <= hour < 5:
        return "late night"
    if 5 <= hour < 8:
        return "early morning"
    if 8 <= hour < 17:
        return "daytime"
    if 17 <= hour < 21:
        return "evening"
    return "night"


def _resolve_context(lat: float, lng: float) -> dict | None:
    """
    Best-effort spatial lookup. Returns the full find_safe_spots() result
    (current-point risk + ranked nearby safer spots) or None if the engine is
    unavailable — in which case we still answer the user instead of 500'ing.
    """
    try:
        return get_engine().find_safe_spots(lat, lng)
    except Exception as exc:
        print(f"[Chat] Risk engine unavailable (non-fatal): {exc}")
        return None


def _name_for(lat: float, lng: float) -> str | None:
    """Reverse-geocode a point, returning a usable name or None on fallback."""
    name = reverse_geocode(lat, lng)
    return name if name and name != "this location" else None


def _format_safe_spots(spots: list) -> str:
    """Render ranked safe spots as concrete, quotable bullet lines for the LLM."""
    if not spots:
        return (
            "    (No clearly-safer spot was found within ~600m — advise the user "
            "to head toward the nearest busy, well-lit main road or public place.)"
        )
    lines = []
    for s in spots:
        bits = [f"~{s['distance_m']}m {s['direction']}"]
        if s.get("name"):
            bits.append(s["name"])
        bits.append(f"{s['risk_level'].upper()} risk")
        if s.get("strengths"):
            bits.append(", ".join(s["strengths"]))
        lines.append("    - " + " — ".join(bits))
    return "\n".join(lines)


def _build_system_prompt(
    language: str,
    address: str | None,
    hour: int,
    here: dict | None,
    safe_spots: list,
) -> str:
    """
    SENTRA is a dual-mode companion: a warm everyday assistant for women that
    ALSO has live situational awareness. It only escalates to safety mode when
    the user's message is actually about safety/danger — otherwise it just
    chats normally. The live location context is always available but never
    forced into casual conversation.
    """
    where = f"near {address}" if address else "at their current location"
    now = datetime.now().strftime("%H:%M")
    part_of_day = _hour_descriptor(hour)

    if here:
        risk_line = (
            f"- Their immediate area is rated {here.get('risk_level', 'unknown').upper()} "
            f"risk — {here.get('explanation', 'no details available')}.\n"
        )
    else:
        risk_line = "- Live risk data is currently unavailable for their area.\n"

    return (
        "You are SENTRA, a calm, supportive AI companion built for women's "
        "safety and everyday support. You are warm and human, never robotic.\n"
        "\n"
        "LIVE CONTEXT — this is the user's REAL, current situation derived from "
        "their live GPS location and a live risk model. Treat it as ground "
        "truth and use it (only) when it is relevant to their message:\n"
        f"- The user is right now {where}.\n"
        f"- Local time is {now} ({part_of_day}).\n"
        f"{risk_line}"
        "- Nearest safer spots (already computed for you from live risk data, "
        "ranked safest-first):\n"
        f"{_format_safe_spots(safe_spots)}\n"
        "\n"
        "HOW TO RESPOND:\n"
        "- If the user asks where to go, the safest spot near them, how to get "
        "somewhere safe, or whether their surroundings are safe: answer "
        "CONCRETELY using the live context — name the direction and distance of "
        "a safer spot above (and its name if given), and why it's safer. Never "
        "say you don't know their location; you do.\n"
        "- If the user asks about safety more generally, walking alone, feeling "
        "unsafe, or an emergency: give brief, concrete, actionable guidance and "
        "weave in the live context above.\n"
        "- If the user is just chatting (greetings, daily life, questions, "
        "venting): reply naturally and kindly, like a trusted friend. Do NOT "
        "force safety talk, locations, or risk levels when they aren't relevant.\n"
        "- Keep replies concise and easy to read on a phone under stress.\n"
        f"- Always reply in the user's language ({language}).\n"
        "- Only use the spots and facts provided above; never invent places, "
        "addresses, or emergency-service contacts."
    )


# --- Endpoints ---

@router.post("/chat", response_model=ChatResponse)
def safety_chat(request: ChatRequest):
    # Diagnostic: proves the request actually reached the backend. If you DON'T
    # see this line in the uvicorn terminal when you tap send, the problem is the
    # network path (wrong IP / firewall / uvicorn not on 0.0.0.0), not the AI code.
    print(f"[Chat] query={request.query!r} @ ({request.lat},{request.lng}) lang={request.language}")

    # Build live, location-aware context (all best-effort — any failure just
    # degrades the context; the user still gets an answer).
    context = _resolve_context(request.lat, request.lng)
    here = context.get("here") if context else None
    safe_spots = list(context.get("safe_spots") or []) if context else []

    # Name the user's location and the top couple of safe spots so the model can
    # speak in place names, not just bearings. Capped to bound latency / Mapbox
    # calls; missing token or failures degrade silently to direction + distance.
    address = None
    try:
        address = _name_for(request.lat, request.lng)
        for spot in safe_spots[:2]:
            spot["name"] = _name_for(spot["lat"], spot["lng"])
    except Exception as exc:
        print(f"[Chat] Reverse-geocode unavailable (non-fatal): {exc}")

    hour = datetime.now().hour
    system_prompt = _build_system_prompt(
        request.language, address, hour, here, safe_spots
    )

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
