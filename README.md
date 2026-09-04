# ruby-ai-stream

English | [日本語](README.ja.md)

`ruby-ai-stream` converts events from Ruby AI SDKs into [AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) SSE. It lets you keep an AI agent backend in Rails while using AI SDK's `useChat` on the client.

The provider-neutral core consists of `AgentStream::UIMessage::V1::Event` and `AgentStream::UIMessage::V1::Stream`. OpenAI, Anthropic, and RubyLLM support lives in separate adapters; the stream itself has no dependency on their SDK classes.

```text
OpenAI / Anthropic / RubyLLM events
                 ↓
        provider adapter
                 ↓ Enumerable<Event>
         ui_stream << event
                 ↓
  UI Message Stream Protocol v1 SSE
                 ↓
              useChat
```

## Design

The only write interface is `ui_stream << event`.

- `Event` validates the event type, required and optional fields, and JSON compatibility when it is created.
- `Stream` validates message, step, part, and tool lifecycle ordering and serializes events as SSE frames.
- `Adapters::*` interprets provider SDK events, accumulates streamed tool input JSON, and maps provider metadata.

A new provider can be supported outside this gem by implementing an `Enumerable<AgentStream::UIMessage::V1::Event>`.

## Installation

Use a local checkout before the gem is published:

```ruby
gem "ruby-ai-stream", path: "../ruby-ai-stream"
```

Add only the provider SDKs your application uses. They are not runtime dependencies of this gem.

```ruby
gem "openai", "~> 0.85"       # OpenAI adapter
gem "anthropic", "~> 1.68"   # Anthropic adapter
gem "ruby_llm", "~> 1.16"    # RubyLLM adapter
```

Ruby 3.3 or later is required.

## Basic API

Write protocol events directly when no provider adapter is needed:

```ruby
require "ai_stream"

Event = AgentStream::UIMessage::V1::Event
ui_stream = AgentStream::UIMessage::V1::Stream.new

ui_stream << Event.new(:start, message_id: "assistant-1")
ui_stream << Event.new(:start_step)
ui_stream << Event.new(:text_start, id: "text-1")
ui_stream << Event.new(:text_delta, id: "text-1", delta: "Hello")
ui_stream << Event.new(:text_end, id: "text-1")
ui_stream << Event.new(:finish_step)
ui_stream << Event.new(:finish, finish_reason: :stop)

ui_stream.each { |frame| puts frame }
```

Pass a sink implementing `#write(String)`, such as `response.stream`, to write frames immediately. Without a sink, frames are retained for a Rack body or tests. A terminal event (`finish`, `abort`, or `error`) automatically appends `data: [DONE]`.

Invalid fields and JSON values raise `Event::SchemaError` or `Event::JSONCompatibilityError`. Invalid ordering raises `Stream::ProtocolError`. RBS declares the same public event surface with overloads.

## Provider adapters

### OpenAI

```ruby
require "openai"
require "ai_stream/adapters/openai"

sdk_stream = OpenAI::Client.new.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: "Write one short greeting."
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::OpenAI.new(sdk_stream).each { |event| ui_stream << event }
```

The adapter consumes the official [`openai-ruby`](https://github.com/openai/openai-ruby) Responses stream and maps text, refusal, reasoning, function-call input, usage, completion, and failure events. Unknown future `response.*` events are ignored for forward compatibility; unrelated values raise `UnsupportedEventError`.

### Anthropic

```ruby
require "anthropic"
require "ai_stream/adapters/anthropic"

sdk_stream = Anthropic::Client.new.messages.stream(
  model: ENV.fetch("ANTHROPIC_MODEL"),
  max_tokens: 512,
  messages: [{ role: :user, content: "Write one short greeting." }]
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::Anthropic.new(sdk_stream).each { |event| ui_stream << event }
```

The adapter consumes the official [`anthropic-sdk-ruby`](https://github.com/anthropics/anthropic-sdk-ruby) `MessageStream`. It maps raw text, thinking, signatures, tool use, usage, and stop reasons while avoiding duplicate helper events. Client tools become ordinary tool events; server and MCP tool use sets `providerExecuted: true`.

### RubyLLM

```ruby
require "ruby_llm"
require "ai_stream/adapters/ruby_llm"

sdk_events = Enumerator.new do |events|
  RubyLLM.chat.ask("Write one short greeting.") { |chunk| events << chunk }
end

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::RubyLLM.new(sdk_events).each { |event| ui_stream << event }
```

The RubyLLM adapter handles text, thinking, URL attachments, streamed or structured tool calls, and tool-result `RubyLLM::Message` objects. To include tool results from an agent loop, add messages for which `message.tool_result?` is true to the same enumerator from an `after_message` callback.

## Rails and `useChat`

The controller owns HTTP transport, `Stream` owns SSE serialization, and an adapter owns provider conversion:

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)
    ui_stream.headers.each { |name, value| response.headers[name] = value }

    model.stream_events(params.require(:prompt)).each do |provider_event|
      ui_stream << AgentStream::UIMessage::V1::Event.new(
        provider_event.type,
        **provider_event.payload
      )
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("UI message client disconnected")
  ensure
    response.stream.close
  end
end
```

Set headers before the first event and always close the response stream. AI SDK's `DefaultChatTransport` and `useChat` can consume the endpoint directly.

## Custom adapters

A custom adapter only needs to consume provider events and yield validated events:

```ruby
class MyProviderAdapter
  include Enumerable

  def initialize(events)
    @events = events
  end

  def each
    return enum_for(:each) unless block_given?

    yield AgentStream::UIMessage::V1::Event.new(:start)
    yield AgentStream::UIMessage::V1::Event.new(:start_step)
    # Convert @events and yield Event instances here.
    yield AgentStream::UIMessage::V1::Event.new(:finish_step)
    yield AgentStream::UIMessage::V1::Event.new(:finish, finish_reason: :stop)
    self
  end
end
```

Adapter output still passes through `ui_stream << event`, so it cannot bypass event schema or lifecycle validation.

## Examples

- `examples/openai.rb`: official OpenAI Responses stream
- `examples/anthropic.rb`: official Anthropic Messages stream
- `examples/ruby_llm.rb`: RubyLLM callback exposed as an `Enumerator`
- `examples/rails_demo`: plain model events converted to `Event` and written as Rails SSE
- `examples/react_client`: the Rails demo consumed by `@ai-sdk/react` `useChat`

Run the Rails and React end-to-end demo:

```bash
cd examples/rails_demo
bundle install
bin/rails test
bin/rails server -b 127.0.0.1 -p 3000

cd ../react_client
npm install
npm test
npm run dev
```

## Tests

```bash
bundle exec rake test
bundle exec rbs validate
bundle exec rubocop
gem build ruby-ai-stream.gemspec
```

OpenAI and Anthropic fixtures are restored through their official SDK model converters. RubyLLM tests instantiate its real event classes. Every adapter's output is then passed through the real `UIMessage::V1::Stream`.

## Scope

This gem does not choose models, persist conversations, execute tools, define approval policies, retry requests, or manage Rails threads. Its responsibility ends after converting provider events into common events and safely emitting AI SDK UI Message Stream Protocol v1.

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).
