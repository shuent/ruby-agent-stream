## [Unreleased]

- Replaced the RubyLLM-specific stream with validated, provider-neutral
  `AIStream::UIMessage::V1::Event` and `Stream` types.
- Added adapters for RubyLLM, official OpenAI Responses streams, and official
  Anthropic Messages streams.
- Added runtime event-schema and protocol-order validation, RBS signatures,
  real SDK model fixtures, and provider-neutral examples.

## [0.1.0] - 2026-09-04

- Initial release
