import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Set up dummy environment variables for imports
os.environ["MAPBOX_ACCESS_TOKEN"] = "pk.dummy_mapbox_token"
os.environ["SARVAM_API_KEY"] = "dummy_sarvam_key"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
from main import app
from services.sarvam_client import reverse_geocode, generate_text, generate_tts

client = TestClient(app)

class TestSarvamService(unittest.TestCase):
    @patch("services.sarvam_client.requests.get")
    def test_reverse_geocode_success(self, mock_get):
        # Mock successful mapbox response
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "features": [{"properties": {"full_address": "123 Safe St"}}]
        }
        mock_get.return_value = mock_response

        address = reverse_geocode(17.0, 78.0)
        self.assertEqual(address, "123 Safe St")

    @patch("services.sarvam_client.requests.get")
    def test_reverse_geocode_fallback(self, mock_get):
        # Mock failure/timeout to trigger fallback
        from requests.exceptions import RequestException
        mock_get.side_effect = RequestException("Timeout")

        address = reverse_geocode(17.0, 78.0)
        self.assertEqual(address, "this location")  # Exact strict fallback required by audit

    @patch("services.sarvam_client.requests.post")
    def test_generate_text_payload(self, mock_post):
        mock_response = MagicMock()
        mock_response.json.return_value = {"choices": [{"message": {"content": "Hello"}}]}
        mock_post.return_value = mock_response

        generate_text("Test prompt")
        # Verify the payload targets the valid Sarvam chat model strictly
        called_args, called_kwargs = mock_post.call_args
        payload = called_kwargs.get("json")
        self.assertEqual(payload.get("model"), "sarvam-30b")
        self.assertEqual(payload.get("temperature"), 0.3)

    @patch("services.sarvam_client.requests.post")
    def test_generate_tts_payload(self, mock_post):
        mock_response = MagicMock()
        mock_response.json.return_value = {"audios": ["base64_audio_string"]}
        mock_post.return_value = mock_response

        b64 = generate_tts("Test script")
        # Verify the payload strictly triggers Bulbul V3
        called_args, called_kwargs = mock_post.call_args
        payload = called_kwargs.get("json")
        self.assertEqual(payload.get("model"), "bulbul:v3")
        self.assertEqual(b64, "base64_audio_string")

class TestAIAssistantEndpoints(unittest.TestCase):
    @patch("routes.ai_assistant.reverse_geocode")
    @patch("routes.ai_assistant.get_engine")
    @patch("routes.ai_assistant.generate_text")
    def test_chat_endpoint(self, mock_generate_text, mock_get_engine, mock_reverse_geocode):
        # The chat endpoint now enriches the prompt with nearby safe spots and a
        # reverse-geocoded area name. Mock both so no network/data is needed.
        mock_engine = MagicMock()
        mock_engine.find_safe_spots.return_value = {
            "here": {"risk_level": "high", "explanation": "Dark alley", "risk_score": 75.0},
            "safe_spots": [
                {
                    "lat": 17.31, "lng": 78.41, "direction": "north-east",
                    "distance_m": 300, "risk_score": 30.0, "risk_level": "low",
                    "strengths": ["well-lit", "usually busy"],
                },
            ],
        }
        mock_get_engine.return_value = mock_engine
        mock_reverse_geocode.return_value = "Banjara Hills Rd"

        mock_generate_text.return_value = "Head north-east toward Banjara Hills Rd."

        response = client.post(
            "/ai/chat",
            json={"query": "What's the safest spot near me?", "lat": 17.3, "lng": 78.4, "language": "en-US"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"reply": "Head north-east toward Banjara Hills Rd."})

        # The live context must actually reach the LLM: assert the system prompt
        # carries the named safe spot and its direction/distance.
        _, kwargs = mock_generate_text.call_args
        system_prompt = kwargs.get("system", "")
        self.assertIn("Banjara Hills Rd", system_prompt)
        self.assertIn("north-east", system_prompt)
        self.assertIn("300m", system_prompt)

    @patch("routes.ai_assistant.reverse_geocode")
    @patch("routes.ai_assistant.generate_text")
    @patch("routes.ai_assistant.generate_tts")
    def test_deterrent_endpoint(self, mock_tts, mock_text, mock_geocode):
        mock_geocode.return_value = "Main St"
        mock_text.return_value = "All units to Main St."
        mock_tts.return_value = "base64data"

        response = client.post(
            "/ai/deterrent",
            json={"lat": 17.3, "lng": 78.4, "language": "en-US"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {
            "script": "All units to Main St.",
            "audio_base64": "base64data"
        })

class TestRiskEngineSafeSpots(unittest.TestCase):
    """Locks the new nearby-safe-spot scan that powers location-aware chat."""

    @classmethod
    def setUpClass(cls):
        from risk_engine import HyderabadRiskEngine
        cls.engine = HyderabadRiskEngine()

    def test_find_safe_spots_structure(self):
        # A point inside the Hyderabad dataset coverage.
        result = self.engine.find_safe_spots(17.4400, 78.4500, hour=23)

        self.assertIn("here", result)
        self.assertIn("safe_spots", result)
        self.assertIn("risk_score", result["here"])

        spots = result["safe_spots"]
        self.assertLessEqual(len(spots), 3)
        for spot in spots:
            for key in ("direction", "distance_m", "risk_score", "risk_level", "lat", "lng"):
                self.assertIn(key, spot)

        # Spots must be ranked safest-first (ascending risk score).
        scores = [s["risk_score"] for s in spots]
        self.assertEqual(scores, sorted(scores))


if __name__ == "__main__":
    unittest.main()
