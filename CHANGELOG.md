## [Unreleased]

- Added `Stream.new(continuation: saved_events)` to restore protocol validation
  across completed HTTP streams without replaying old SSE frames, including
  AI SDK standard tool approval responses and outputs.
- Preserved RubyLLM 1.16 compatibility while accepting the 2.0 development SDK's
  model, finish-reason, and JSON tool-result message contracts.
- Removed OpenAI/Anthropic adapters and lifecycle modes. OpenAI examples now
  own their SDK requests, tool execution, context, and turn boundaries directly.
- Made the optional RubyLLM adapter self-contained and added a primitive
  Event array / Enumerator / stdout example.
- Simplified RubyLLM conversion to streamed text/thinking chunks and completed
  `after_message` messages. Removed partial tool-input reconstruction; finalized
  tool calls, results, and usage now come directly from RubyLLM.
- Replaced the RubyLLM-specific stream with validated, provider-neutral
  `AgentStream::UIMessage::V1::Event` and `Stream` types.
- Added an optional RubyLLM adapter.
- Added runtime event-schema and protocol-order validation, RBS signatures,
  real SDK model fixtures, and provider-neutral examples.

## [0.1.0] - 2026-09-04

- Initial release
