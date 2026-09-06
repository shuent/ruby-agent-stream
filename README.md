# ruby-agent-stream

English | [日本語](README.ja.md)

`ruby-agent-stream` serializes events from Ruby applications as [AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) SSE. It lets you keep an AI agent backend in Rails while using AI SDK's `useChat` on the client.

The provider-neutral core consists of `AgentStream::UIMessage::V1::Event` and `AgentStream::UIMessage::V1::Stream`. The stream has no dependency on provider SDK classes. A RubyLLM adapter is an optional convenience: RubyLLM owns the agent loop, and the adapter converts its output.

```text
Application events / optional RubyLLM adapter
                 ↓ Enumerable<Event>
         ui_stream << event
                 ↓
  UI Message Stream Protocol v1 SSE
                 ↓
              useChat
```

## demo rails ai agent saas app gif

![](images/rails-real-agent/live-agent-flow.gif)

## Design

The only write interface is `ui_stream << event`.

- `Event` validates the event type, required and optional fields, and JSON compatibility when it is created.
- `Stream` validates message, step, part, and tool lifecycle ordering and serializes events as SSE frames.
- `Adapters::RubyLLM` optionally converts RubyLLM chunks and completed messages.

A new provider can be supported outside this gem by implementing an `Enumerable<AgentStream::UIMessage::V1::Event>`.

## Installation

Use a local checkout before the gem is published:

```ruby
gem "ruby-agent-stream", git: "git@github.com:shuent/ruby-agent-stream.git"
```

Add only the provider SDKs your application uses. They are not runtime dependencies of this gem.

```ruby
gem "openai", "~> 0.85"       # Direct SDK agent example
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

For a runnable array → Enumerator → `ui_stream << event` → stdout example, see [examples/primivitve.rb](examples/primivitve.rb). No provider SDK or API key is needed.

```bash
bundle exec ruby -Ilib examples/primivitve.rb
```

### Approval across HTTP requests

After `tool-input-available` and `tool-approval-request`, close the step and finish
the HTTP stream. AI SDK's `addToolApprovalResponse` updates the existing tool
part; configure `sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithApprovalResponses`
to submit that decision in a new request. On the server, restore protocol state
from the saved `Event` history without replaying its SSE frames:

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream, continuation: saved_events)
ui_stream << Event.new(:start, message_id: original_assistant_id)
ui_stream << Event.new(:start_step)
ui_stream << Event.new(:tool_approval_response, approval_id: approval_id, approved: true)
ui_stream << Event.new(:tool_output_available, tool_call_id: original_tool_call_id, output: result)
ui_stream << Event.new(:finish_step)
ui_stream << Event.new(:finish)
```

For rejection, send `approved: false` followed by `tool_output_denied`.
`continuation:` accepts an enumerable of validated `Event` objects from one or
more completed HTTP segments of the same assistant message, each ending with
`finish`. Incomplete, aborted, and failed histories are rejected. The caller
must use the original assistant ID and trusted server history. This restores
protocol validation only: the application owns approval persistence, identity
and argument binding, authorization, stale decisions, and exactly-once tool
execution. Never execute tools by replaying event history.

## Direct OpenAI SDK agent

OpenAI and Anthropic adapters are not provided. The application owns SDK requests, context storage, tool execution, and continuation/stop decisions, and emits `Event` objects directly. Adapters are optional conveniences.

[examples/openai.rb](examples/openai.rb) is a minimal Rails-free agent. It receives each full response with `responses.create`, executes a demo `weather` function, and sends its result in the next request.

```bash
OPENAI_MODEL=your-model bundle exec ruby -Ilib examples/openai.rb "What is the weather in Tokyo?"
```

Set `OPENAI_API_KEY` before running. This example chooses `store: true` and `previous_response_id`, and resends instructions on every request. A completed response ends one generation. If `response.output` contains `function_call` items, execute all of them and send matching `function_call_output` items; otherwise return the turn to the user. See the official [function calling guide](https://developers.openai.com/api/docs/guides/function-calling) and [Responses API](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).

One turn is one UI message; each generation and its tool results share a step. `OpenaiExample.events(..., summarize: false)` displays tool results and stops without another request. `max_steps:` defaults to six; exhausted limits, failures, and incomplete responses end with an `error`. The Rails example implements its own policy with streaming text/reasoning and approval continuation over HTTP.

## Optional RubyLLM adapter


```ruby
require "ruby_llm"
require "ai_stream/adapters/ruby_llm"

sdk_events = Enumerator.new do |events|
  chat = RubyLLM.chat
  chat.after_message { |message| events << message }
  chat.ask("Write one short greeting.") { |chunk| events << chunk }
end

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::RubyLLM.new(sdk_events).each { |event| ui_stream << event }
```

Feed both `ask` chunks and **all `after_message` messages** into the same enumerator, in callback order. Text and thinking stream from chunks; completed assistant messages supply tool inputs and usage, and tool-result messages supply outputs. Completed text is not emitted again. Partial tool-call chunks are ignored: tool inputs appear only once RubyLLM has assembled them.

RubyLLM owns tool execution, waiting, and continuation. The adapter only adds UI boundaries: each generation and its tool results share a step, and the next generation starts a new step. Enumeration ending finishes the UI message. Usage is summed from completed assistant messages, without counting chunk snapshots again. RubyLLM 1.16 URL content attachments remain supported.

## Rails and `useChat`

The controller owns HTTP transport, `Stream` owns SSE serialization, and the application agent executes work and creates events. The RubyLLM adapter can help with conversion:

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

## Optional custom adapters

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

- `examples/primivitve.rb`: Event array → Enumerator → stdout SSE
- `examples/openai.rb`: direct OpenAI SDK agent loop (Rails-free)
- `examples/ruby_llm.rb`: RubyLLM callback exposed as an `Enumerator`
- `examples/rails_demo`: plain model events converted to `Event` and written as Rails SSE
- `examples/react_client`: the Rails demo consumed by `@ai-sdk/react` `useChat`

Run the Rails and React end-to-end demo:

```bash
# From the repository root
bin/dev
```

Open http://127.0.0.1:5173/. This prepares the demo database and starts Rails and Vite; Ctrl-C stops both. You can also run `bin/dev` from `examples/rails_demo`. See [the example README](examples/rails_demo/README.md) for API setup and verification.

## Tests

```bash
bundle exec rake test
bundle exec rbs validate
bundle exec rubocop
gem build ruby-agent-stream.gemspec
```

Example agent tests use fake provider responses restored through the real OpenAI SDK model converter, without API calls. RubyLLM tests instantiate its real event classes. Outputs pass through the real `UIMessage::V1::Stream`.

## Scope

This gem does not choose models, persist conversations, execute tools, define approval policies, retry requests, or manage Rails threads. Its responsibility ends after converting provider events into common events and safely emitting AI SDK UI Message Stream Protocol v1.

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).
