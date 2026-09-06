# ruby-agent-stream

[English](README.md) | 日本語

Ruby アプリが作る event を、[AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) の SSE に変換するための小さなライブラリです。

中心にあるのは provider 非依存の `AgentStream::UIMessage::V1::Event` と `AgentStream::UIMessage::V1::Stream` です。Stream 自体は SDK の class を知りません。RubyLLM adapter は任意の補助機能です。RubyLLM が agent loop を制御し、その出力を adapter が変換します。

```text
アプリが直接作る Event / 任意の RubyLLM adapter
                ↓ Enumerable<Event>
        ui_stream << event
                ↓
 UI Message Stream Protocol v1 SSE
```

## demo rails ai agent saas app gif

![](images/rails-real-agent/live-agent-flow.gif)


## 設計

書き込み interface は `ui_stream << event` だけです。

役割は次のように分離しています。

- `Event`: event type、必須／任意 field、JSON 互換性を生成時に検証する
- `Stream`: message、step、part、tool の順序を検証し、SSE frame にする
- `Adapters::RubyLLM`（任意）: RubyLLM の Chunk / 確定した Message 列を変換する

この境界により、新しい provider は gem 本体を変更せず `Enumerable<AgentStream::UIMessage::V1::Event>` を実装すれば追加できます。

## Installation

公開前の checkout を使う場合:

```ruby
gem "ruby-agent-stream", git: "git@github.com:shuent/ruby-agent-stream.git"
```

使う provider SDK だけを application 側に追加します。この gem はすべての SDK を runtime dependency にはしません。

```ruby
gem "openai", "~> 0.85"       # Direct SDK agent example
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

配列 → Enumerator → `ui_stream << event` → stdout の実行例は [examples/primivitve.rb](examples/primivitve.rb) です。SDK・API key は不要です。

```bash
bundle exec ruby -Ilib examples/primivitve.rb
```

### 別 HTTP request で承認を継続する

`tool-input-available` と `tool-approval-request` の後にstepとHTTP streamを終了します。
AI SDKの `addToolApprovalResponse` は既存tool partを更新し、
`sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithApprovalResponses` を設定すると
判断が新しいHTTP requestとして送信されます。server保存の `Event` 履歴から検証状態だけを復元できます。
過去のSSE frameは再送しません。

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream, continuation: saved_events)
ui_stream << Event.new(:start, message_id: original_assistant_id)
ui_stream << Event.new(:start_step)
ui_stream << Event.new(:tool_approval_response, approval_id: approval_id, approved: true)
ui_stream << Event.new(:tool_output_available, tool_call_id: original_tool_call_id, output: result)
ui_stream << Event.new(:finish_step)
ui_stream << Event.new(:finish)
```

拒否時は `approved: false` と `tool_output_denied` を送ります。`continuation:` は同じassistant
messageの1つ以上のHTTP区間を構成する `Event` 列を受け取り、各区間は `finish` で終了している必要があります。
途中・abort・errorの履歴は拒否します。元のassistant IDと信頼できるserver履歴を渡すのはcallerの責務です。
復元するのはprotocol検証状態だけです。承認の永続化、本人・確定引数との対応付け、認可、陳腐化判定、
一度だけのtool実行はアプリ側で担い、event履歴のreplayからtoolを実行しないでください。

## OpenAI SDK を直接使う agent

OpenAI / Anthropic adapter は提供しません。SDK 呼び出し、context の保存、tool 実行、継続・停止条件はアプリ自身で実装し、`Event` を直接出力します。adapter の利用は任意です。

[examples/openai.rb](examples/openai.rb) は Rails 非依存の最小 agent です。`responses.create` で応答全体を受け取り、demo の `weather` 関数を実行して結果を次の呼び出しへ渡します。

```bash
OPENAI_MODEL=your-model bundle exec ruby -Ilib examples/openai.rb "東京の天気は？"
```

`OPENAI_API_KEY` が必要です。この例は `store: true` と `previous_response_id` を使い、instructions を毎回送ります。`completed` は生成1回の終了です。`response.output` に `function_call` があれば全件実行して `function_call_output` を返し、なければユーザーへターンを返します。[公式 function calling ガイド](https://developers.openai.com/api/docs/guides/function-calling)、[Responses API](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)を参照してください。

1ターンは1メッセージ、生成＋その tool 結果は1stepです。`OpenaiExample.events(..., summarize: false)` は tool 結果を UI に表示して終了し、再問い合わせしません。`max_steps:` は既定6回で、上限・失敗・不完全応答は `error` で終了します。Rails example は同じ判断を独自に実装し、text / reasoning delta の逐次表示と承認の HTTP 継続も扱います。

## RubyLLM adapter（任意）


RubyLLM は callback で chunk を返すため、`Enumerator` で SDK event stream にします。

```ruby
require "ruby_llm"
require "ai_stream/adapters/ruby_llm"

sdk_events = Enumerator.new do |events|
  chat = RubyLLM.chat
  chat.after_message { |message| events << message }
  chat.ask("Write one short greeting.") do |chunk|
    events << chunk
  end
end

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::RubyLLM.new(sdk_events).each do |event|
  ui_stream << event
end
```

`ask` の chunk と **`after_message` のすべての Message** を、callback 順に同じ Enumerator に渡します。本文と thinking は chunk から流し、tool input と usage は確定した assistant Message、tool output は tool-result Message から変換します。確定 Message の本文は重複して流しません。tool call の断片は無視し、RubyLLM が組み立て終わった引数だけを表示します。

tool の実行・待機・推論の継続は RubyLLM に任せます。adapter が補うのは UI の境界だけです。各生成とその tool result は同じ step に入り、次の生成で新しい step を開始し、列挙終了で UI message を終了します。usage は確定した assistant Message から合算し、chunk の途中集計を二重に数えません。RubyLLM 1.16 の URL content attachment にも対応します。

## Rails (`ActionController::Live`)

controller が HTTP transport、Stream が SSE、アプリの agent が実行と Event の生成を担当します。RubyLLM の変換には任意の adapter を利用できます。

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

## 任意の独自 adapter

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

- `examples/primivitve.rb`: Event array → Enumerator → stdout SSE
- `examples/openai.rb`: direct OpenAI SDK agent loop (Rails-free)
- `examples/ruby_llm.rb`: RubyLLM callback を Enumerator に接続
- `examples/rails_demo`: plain model event → `Event` → Rails SSE の流れをControllerに示すdemo
- `examples/react_client`: `@ai-sdk/react` の `useChat` で Rails demo を消費

Rails と React の end-to-end demo:

```bash
# リポジトリルートから
bin/dev
```

http://127.0.0.1:5173/ を開きます。DB準備とRails・Viteの起動をまとめて行い、Ctrl-Cで両方停止します。`examples/rails_demo` 内の `bin/dev` からも起動できます。API設定と検証方法は[サンプルのREADME](examples/rails_demo/README.md)を参照してください。

## Tests

```bash
bundle exec rake test
bundle exec rbs validate
bundle exec rubocop
gem build ruby-agent-stream.gemspec
```

非課金の provider 応答を実 OpenAI SDK model に復元して example の agent loop を検証します。RubyLLM は実 class を構築して変換します。出力は実際の `UIMessage::V1::Stream` に通します。

## Scope

この gem は model 選択、conversation 保存、tool 実行、approval policy、retry、Rails の thread 管理を行いません。provider event を共通 Event に変換し、その Event を UI Message Stream Protocol v1 として安全に出力するところまでが責務です。

## License

MIT. See [`LICENSE.txt`](LICENSE.txt).
