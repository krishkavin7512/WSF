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
    @patch("routes.ai_assistant.get_engine")
    @patch("routes.ai_assistant.generate_text")
    def test_chat_endpoint(self, mock_generate_text, mock_get_engine):
        mock_engine = MagicMock()
        mock_engine.get_risk_score.return_value = {"risk_level": "high", "explanation": "Dark alley"}
        mock_get_engine.return_value = mock_engine
        
        mock_generate_text.return_value = "Stay away."
        
        response = client.post(
            "/ai/chat",
            json={"query": "Is it safe?", "lat": 17.3, "lng": 78.4, "language": "en-US"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"reply": "Stay away."})

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

if __name__ == "__main__":
    unittest.main()
