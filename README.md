# RubyLLM::Stream::AISDK

`RubyLLM::Stream::AISDK` is a zero-JavaScript-server adapter from
[`RubyLLM::Chunk`](https://rubyllm.com/streaming/) to the
[AI SDK UI Message Stream Protocol](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol).
It lets a Rails endpoint stream RubyLLM output directly to an
[`@ai-sdk/react` `useChat`](https://ai-sdk.dev/docs/reference/ai-sdk-ui/use-chat)
client.

It does not depend on `tachyurgy/ai_stream`, Vercel's JavaScript packages, or an
AI provider SDK. The only runtime dependency is RubyLLM.

## What it covers

- Lazy `start` / `start-step` lifecycle around ordinary RubyLLM chunks
- Text and reasoning start/delta/end parts
- Streamed and structured tool input, tool result messages, tool errors, and
  denied output
- Tool approval request/response and preliminary output
- URL/document sources, files, reasoning files, metadata, custom events, and
  `data-*` events
- Step reset, finish, abort, stream error, and the final `[DONE]` marker
- Strict event ordering and JSON-compatibility validation
- Direct IO output for `ActionController::Live` and buffered `Enumerable`
  output for tests or ordinary Rack bodies

The implementation targets UI Message Stream Protocol v1 as consumed by
`ai` 7.0.92 and `@ai-sdk/react` 4.0.95. The repository's deterministic demo
also verifies the protocol in a real Chromium session.

## Installation

Until the gem is published, point Bundler at this checkout:

```ruby
gem "ruby_llm-ai_sdk", path: "../ruby-ai-stream"
```

Then require the adapter:

```ruby
require "ruby_llm/ai_sdk"
```

Ruby 3.2 or newer and RubyLLM 1.16.x are supported by the gemspec. The CI
matrix is configured for Ruby 3.2, 3.3, 3.4, and 4.0.

## Rails streaming

`ActionController::Live` owns the transport. The adapter owns the protocol and
RubyLLM event translation:

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    stream = nil
    stream = RubyLLM::Stream::AISDK.new(
      response.stream,
      message_id: "assistant-#{params.dig(:messages, -1, :id)}"
    )
    stream.headers.each { |name, value| response.headers[name] = value }

    chat = RubyLLM.chat
    chat.ask(user_prompt) { |chunk| stream << chunk }
    stream.finish(finish_reason: :stop)
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("AI SDK client disconnected")
  rescue StandardError => error
    Rails.logger.error(error.full_message)
    terminate_failed_stream(stream)
  ensure
    response.stream.close
  end

  private

  def user_prompt
    message = params.require(:messages).last
    message.fetch(:parts).find { |part| part[:type] == "text" }.fetch(:text)
  end

  def terminate_failed_stream(stream)
    stream&.error(error_text: "Agent stream failed") unless stream&.finished?
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("AI SDK client disconnected while reporting an error")
  end
end
```

Set every response header before the first write and always close the Rails
response stream. `finish`, `abort`, and `error` are terminal: each writes its
protocol event followed by `data: [DONE]` and rejects later writes.

On the React side, no custom SSE parser or message accumulator is needed:

```tsx
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";

const { messages, sendMessage, status, stop } = useChat({
  transport: new DefaultChatTransport({ api: "/chat" }),
});
```

## RubyLLM mapping

The common path is intentionally one line:

```ruby
chat.ask("What is the weather?") { |chunk| stream << chunk }
```

The adapter maps RubyLLM content, thinking, and streamed tool calls. RubyLLM
tool-result messages are not yielded to the same stream block, so forward them
from a message callback when an agent executes tools:

```ruby
chat.after_message do |message|
  stream.write_message(message) if message.tool_result?
end
```

RubyLLM chunks currently do not carry citations, files, approvals, or finish
reasons. Emit those through the typed API:

```ruby
stream.source_url(
  source_id: "ruby-llm",
  url: "https://rubyllm.com/",
  title: "RubyLLM"
)

stream.data(name: "progress", id: "job-1", data: { value: 50 })

stream.tool_approval_request(
  approval_id: "approval-1",
  tool_call_id: "call-1",
  reason: "This tool writes external state"
)
stream.tool_approval_response(approval_id: "approval-1", approved: true)
stream.tool_output_available(tool_call_id: "call-1", output: { ok: true })
```

All public methods return the stream, so explicit event sequences may be
chained. Invalid ordering raises `RubyLLM::Stream::AISDK::ProtocolError`;
unsupported JSON values raise `JSONCompatibilityError`.

## Buffered mode

Omit the IO sink to retain frames in memory. The adapter then acts as an
`Enumerable`, which is useful for unit tests and non-live Rack responses:

```ruby
stream = RubyLLM::Stream::AISDK.new(message_id: "assistant-1")
stream << RubyLLM::Chunk.new(role: :assistant, content: "Hello")
stream.finish(finish_reason: :stop)

[200, stream.headers, stream]
```

When an IO sink is supplied, frames are written immediately and are not also
retained in memory.

## Run the end-to-end demo

The example does not call an AI API. A deterministic Rails model produces every
supported agent-style event, while the React application consumes the real SSE
response with `useChat`.

Terminal 1:

```bash
cd examples/rails_demo
bundle install
bin/rails server -b 127.0.0.1 -p 3000
```

Terminal 2:

```bash
cd examples/react_client
npm install
npm run dev
```

Open `http://127.0.0.1:5173`. The four scenarios exercise completion, a
server-originated abort, protocol error, and browser cancellation.

With the pinned AI SDK versions, `useChat` consumes a server `abort` event and
finishes at `ready`, but its `onFinish.isAbort` flag is reserved for a local
`stop()` / aborted request. Applications that must display a server abort reason
should accompany it with application metadata or a `data-*` event.

See [`docs/rails-llm-streaming-talk.md`](docs/rails-llm-streaming-talk.md) for
the Japanese article/talk draft, real response excerpts, and the browser
verification record. The separate-agent API and abstraction assessment is in
[`docs/abstraction-review.md`](docs/abstraction-review.md).

## Tests

```bash
bundle exec rake
bundle exec rbs -I sig validate

cd examples/rails_demo && bin/rails test
cd ../react_client && npm test && npm run build
```

The protocol suite checks every event shape, sequencing errors, JSON validation,
IO output, Rack enumeration, RubyLLM chunk translation, and terminal behavior.

## Design boundary

This gem is deliberately an adapter, not a chat framework. It does not select
models, persist conversations, run tools, authorize approvals, retry requests,
or own Rails thread capacity. Applications keep those policies; this class
turns their RubyLLM and agent events into a client runtime's wire contract.

Provider-specific streamed tool-call behavior is limited by the normalized
data RubyLLM exposes. Anthropic-style indexed fragments can be correlated;
providers that expose only “latest invocation” fragments cannot make ambiguous
parallel calls safe at this layer. Such ambiguity raises a protocol error where
it can be detected.

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).
