import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_app/services/ai_api_service.dart';
import 'package:mobile_app/theme/sentra_design.dart';

/// A brutalist monochrome chat sheet that adheres strictly to the Sentra
/// design system: 0px border radius, #000/#FFF only, no gradients, no shadows.
///
/// Open with:
/// ```dart
/// showModalBottomSheet(
///   context: context,
///   isScrollControlled: true,  // Required — lets the sheet resize with the keyboard
///   builder: (_) => ChatOverlay(lat: lat, lng: lng),
/// );
/// ```
class ChatOverlay extends StatefulWidget {
  final double lat;
  final double lng;
  final String language;

  const ChatOverlay({
    super.key,
    required this.lat,
    required this.lng,
    this.language = 'en-IN',
  });

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends State<ChatOverlay> {
  final AiApiService _ai = AiApiService();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _isSending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _isSending) return;

    _controller.clear();
    setState(() {
      _messages.add(_ChatMessage(text: query, isUser: true));
      _isSending = true;
    });
    _scrollToBottom();

    final reply = await _ai.sendChatQuery(
      query: query,
      lat: widget.lat,
      lng: widget.lng,
      language: widget.language,
    );

    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage(
        text: reply ?? '⚠ SENTRA is unavailable. Stay alert.',
        isUser: false,
      ));
      _isSending = false;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Adjustment #4: viewInsets.bottom lifts the sheet above the keyboard.
    // isScrollControlled: true on showModalBottomSheet allows this to work.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      // Hard black background — no gradients, no rounded corners
      color: SentraDesign.uberBlack,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──────────────────────────────────────────────────
          Container(
            height: 48,
            decoration: const BoxDecoration(
              color: SentraDesign.uberBlack,
              border: Border(
                bottom: BorderSide(color: SentraDesign.pureWhite, width: 1),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              'SENTRA TACTICAL ASSISTANT',
              style: GoogleFonts.inter(
                color: SentraDesign.pureWhite,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.0,
              ),
            ),
          ),

          // ── Chat history ─────────────────────────────────────────────────
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.45,
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'Ask SENTRA about your surroundings.',
                      style: GoogleFonts.inter(
                        color: SentraDesign.mutedGray,
                        fontSize: 14,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _BubbleTile(message: _messages[i]),
                  ),
          ),

          // ── Input row ────────────────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              color: SentraDesign.uberBlack,
              border: Border(
                top: BorderSide(color: SentraDesign.pureWhite, width: 1),
              ),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: GoogleFonts.inter(
                      color: SentraDesign.pureWhite,
                      fontSize: 15,
                    ),
                    cursorColor: SentraDesign.pureWhite,
                    decoration: InputDecoration(
                      hintText: 'Is this area safe at night?',
                      hintStyle: GoogleFonts.inter(
                        color: SentraDesign.mutedGray,
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                _isSending
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: SentraDesign.pureWhite,
                          strokeWidth: 2,
                        ),
                      )
                    : GestureDetector(
                        onTap: _sendMessage,
                        child: const Icon(
                          Icons.send,
                          color: SentraDesign.pureWhite,
                          size: 24,
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Individual chat bubble — strictly brutalist, 0px border radius.
class _BubbleTile extends StatelessWidget {
  final _ChatMessage message;
  const _BubbleTile({required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // User = white background / black text.  SENTRA = black bg / white text.
        decoration: BoxDecoration(
          color: message.isUser
              ? SentraDesign.pureWhite
              : SentraDesign.uberBlack,
          border: Border.all(color: SentraDesign.pureWhite, width: 1),
          borderRadius: BorderRadius.zero, // Strictly 0px — per design rules
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Text(
          message.text,
          style: GoogleFonts.inter(
            color: message.isUser
                ? SentraDesign.uberBlack
                : SentraDesign.pureWhite,
            fontSize: 14,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;
  const _ChatMessage({required this.text, required this.isUser});
}
