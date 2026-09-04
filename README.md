# ruby-ai-stream

Ruby の AI SDK が返す event を、[AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) の SSE に変換するための小さなライブラリです。

中心にあるのは provider 非依存の `AgentStream::UIMessage::V1::Event` と `AgentStream::UIMessage::V1::Stream` です。OpenAI、Anthropic、RubyLLM は独立した adapter であり、Stream 自体は各 SDK の class を知りません。

```text
OpenAI / Anthropic / RubyLLM の event
                ↓
       provider adapter
                ↓ Enumerable<Event>
        ui_stream << event
                ↓
 UI Message Stream Protocol v1 SSE
```

## 設計

書き込み interface は `ui_stream << event` だけです。

役割は次のように分離しています。

- `Event`: event type、必須／任意 field、JSON 互換性を生成時に検証する
- `Stream`: message、step、part、tool の順序を検証し、SSE frame にする
- `Adapters::*`: SDK event の解釈、tool input JSON の蓄積、provider metadata の変換を行う

この境界により、新しい provider は gem 本体を変更せず `Enumerable<AgentStream::UIMessage::V1::Event>` を実装すれば追加できます。

## Installation

公開前の checkout を使う場合:

```ruby
gem "ruby-ai-stream", path: "../ruby-ai-stream"
```

使う provider SDK だけを application 側に追加します。この gem はすべての SDK を runtime dependency にはしません。

```ruby
gem "openai", "~> 0.85"       # OpenAI adapter を使う場合
gem "anthropic", "~> 1.68"   # Anthropic adapter を使う場合
gem "ruby_llm", "~> 1.16"    # RubyLLM adapter を使う場合
```

Ruby 3.3 以上が必要です。

## 基本 API

provider を使わず、protocol event を直接送る最小例です。

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

`Stream.new(response.stream)` のように `#write(String)` を持つ sink を渡すと、frame は即時に書き込まれます。sink を省略すると `frames` に保持され、Rack body や test に使えます。terminal event (`finish`、`abort`、`error`) の直後には `data: [DONE]` が自動で追加されます。

不正な field や JSON 値は `Event::SchemaError` / `Event::JSONCompatibilityError`、不正な event 順序は `Stream::ProtocolError` になります。RBS も同じ public event surface を overload で定義しています。

## OpenAI

official [`openai-ruby`](https://github.com/openai/openai-ruby) の Responses stream をそのまま adapter に渡します。

```ruby
require "openai"
require "ai_stream/adapters/openai"

client = OpenAI::Client.new
sdk_stream = client.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: "Write one short greeting."
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::OpenAI.new(sdk_stream).each do |event|
  ui_stream << event
end
```

Responses API の text、refusal、reasoning、function call input、usage、完了／失敗 event を変換します。SDK が追加した未知の `response.*` event は forward compatibility のため無視し、provider と無関係な値は `UnsupportedEventError` にします。

## Anthropic

official [`anthropic-sdk-ruby`](https://github.com/anthropics/anthropic-sdk-ruby) の `MessageStream` は raw event と high-level helper event の両方を yield します。adapter は raw event を変換し、同じ内容の helper event は重複出力しません。

```ruby
require "anthropic"
require "ai_stream/adapters/anthropic"

client = Anthropic::Client.new
sdk_stream = client.messages.stream(
  model: ENV.fetch("ANTHROPIC_MODEL"),
  max_tokens: 512,
  messages: [{ role: :user, content: "Write one short greeting." }]
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::Anthropic.new(sdk_stream).each do |event|
  ui_stream << event
end
```

text、thinking/signature、tool use input、usage、stop reason を変換します。client tool は通常の tool event、server/MCP tool use は `providerExecuted: true` になります。

## RubyLLM

RubyLLM は callback で chunk を返すため、`Enumerator` で SDK event stream にします。

```ruby
require "ruby_llm"
require "ai_stream/adapters/ruby_llm"

sdk_events = Enumerator.new do |events|
  RubyLLM.chat.ask("Write one short greeting.") do |chunk|
    events << chunk
  end
end

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::RubyLLM.new(sdk_events).each do |event|
  ui_stream << event
end
```

chunk の text、thinking、URL attachment、streamed/structured tool call と、tool-result `RubyLLM::Message` を扱います。agent loop の tool result も含める場合は `after_message` callback で `message.tool_result?` の message を同じ Enumerator に追加してください。

## Rails (`ActionController::Live`)

controller が HTTP transport、Stream が SSE、adapter が provider 変換を担当します。

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)
    ui_stream.headers.each { |name, value| response.headers[name] = value }

    model.stream_events(params.require(:prompt)).each do |provider_event|
      ui_stream << AgentStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("UI message client disconnected")
  ensure
    response.stream.close
  end

end
```

headers は最初の event より前に設定し、response stream は必ず close してください。

## 独自 adapter

独自 adapter は provider event を受け取り、検証済み Event を yield するだけです。利用者側で同じ interface の adapter を gem 外に置けます。

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
    # @events を Event に変換して yield
    yield AgentStream::UIMessage::V1::Event.new(:finish_step)
    yield AgentStream::UIMessage::V1::Event.new(:finish, finish_reason: :stop)
    self
  end
end
```

adapter の出力も `ui_stream << event` を通るため、Event の schema と Stream の順序検証を迂回できません。

## Examples

- `examples/openai.rb`: official OpenAI Responses stream
- `examples/anthropic.rb`: official Anthropic Messages stream
- `examples/ruby_llm.rb`: RubyLLM callback を Enumerator に接続
- `examples/rails_demo`: plain model event → `Event` → Rails SSE の流れをControllerに示すdemo
- `examples/react_client`: `@ai-sdk/react` の `useChat` で Rails demo を消費

Rails と React の end-to-end demo:

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

adapter fixture は単なる test double ではありません。保存した実形式 JSON を official OpenAI / Anthropic SDK の model converter で復元し、RubyLLM は実 class (`Chunk`、`Message`、`ToolCall`、`Thinking`) を構築してから変換しています。最後に全 adapter 出力を本物の `UIMessage::V1::Stream` に投入して検証します。

## Scope

この gem は model 選択、conversation 保存、tool 実行、approval policy、retry、Rails の thread 管理を行いません。provider event を共通 Event に変換し、その Event を UI Message Stream Protocol v1 として安全に出力するところまでが責務です。

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).
