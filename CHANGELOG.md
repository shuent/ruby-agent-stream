## [Unreleased]

- Added `Stream.new(continuation: saved_events)` to restore protocol validation
  across completed HTTP streams without replaying old SSE frames, including
  AI SDK standard tool approval responses and outputs.
- Preserved RubyLLM 1.16 compatibility while accepting the 2.0 development SDK's
  model, finish-reason, and JSON tool-result message contracts.
- Added adapter lifecycle modes for composing multiple provider calls into one
  UI message. The OpenAI adapter now exposes its completed response and mapped
  finish reason after enumeration.
- Fixed RubyLLM automatic tool loops to start a new UI step, accept reused
  per-completion tool stream keys, and aggregate usage across provider calls.
- Replaced the RubyLLM-specific stream with validated, provider-neutral
  `AgentStream::UIMessage::V1::Event` and `Stream` types.
- Added adapters for RubyLLM, official OpenAI Responses streams, and official
  Anthropic Messages streams.
- Added runtime event-schema and protocol-order validation, RBS signatures,
  real SDK model fixtures, and provider-neutral examples.

## [0.1.0] - 2026-09-04

- Initial release
