# RailsでAI Agentを書き、`useChat`で表示する

## 結論

RailsでAI Agentを書き、そのstreaming UIをAI SDKの`useChat`で扱えるようにするため、Rubyのprovider SDK eventを [AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) に変換する`ruby-ai-stream`を作った。

使い方の中心はこれだけである。

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)

provider_events.each do |provider_event|
  ui_stream << AgentStream::UIMessage::V1::Event.new(
    provider_event.type,
    **provider_event.payload,
  )
end
```

OpenAI、Anthropic、RubyLLMを使う場合は、それぞれのadapterがprovider固有のeventを`Event`へ変換する。

```ruby
AgentStream::Adapters::OpenAI.new(sdk_stream).each do |event|
  ui_stream << event
end
```

RailsはAgent、tool、DB、認可を担当し続ける。ブラウザでは`useChat`がtext、reasoning、tool call、停止、エラーなどのstreaming stateを担当する。その間をこのライブラリがSSE protocolでつなぐ。

```text
Rails AI Agent
      ↓
provider SDK events
      ↓
AgentStream adapter
      ↓ Event
ui_stream << event
      ↓ UI Message Stream Protocol SSE
AI SDK useChat
```

---

## 実務的なモチベーション

やりたかったのは、Rails applicationの中にAI Agentを書くことだった。

既存のRails applicationには、すでに多くの資産がある。

- Active Recordのデータ
- 認証と認可
- domain service
- background job
- mailerやnotification
- 社内APIや外部serviceとのintegration
- audit log

Agentがこれらをtoolとして使うなら、AgentもRailsに置くのが自然である。LLMを使うためだけにserverをNode.jsへ分離すると、domain logicや権限境界を二重に持つことになりやすい。

一方、browser側のAgent UIは、単に文字列を追記するだけではない。

```text
text streaming
reasoning
tool input streaming
tool result
multi-step execution
stop / abort
retry
error
```

このstate machineをStimulusや独自React hookで一から作るより、AI SDKの`useChat`を使いたい。

つまり必要だった構成は、次の組み合わせだった。

```text
backend: Rails
agent: Ruby
client state: useChat
```

問題は、RailsでAgentを書けるかではない。RubyのSDKが返すeventを、`useChat`が理解できる形式でどう渡すかだった。

---

## Railsのstreamと`useChat`の間にある差

OpenAI、Anthropic、RubyLLMは、それぞれstreaming eventの形が異なる。

OpenAI Responses APIにはtext delta、reasoning、function call arguments、completed、failedなどのeventがある。Anthropic Messages APIにはmessage、content block、input JSON、thinkingなどのeventがある。RubyLLMはcallbackで`Chunk`やtool callを返す。

対して`useChat`が読むのは、AI SDK UI Message Stream Protocolのeventである。

```text
start
start-step
text-start
text-delta
text-end
reasoning-start
reasoning-delta
reasoning-end
tool-input-start
tool-input-delta
tool-input-available
tool-output-available
finish-step
finish
```

名前が似ていても、そのまま転送できるとは限らない。tool argumentsはJSON文字列の途中までしか届かないことがある。adapterはdeltaを蓄積し、入力が完成した時点で`tool-input-available`を作る必要がある。provider固有のstop reasonやusage metadataもprotocol側のfieldへ写す必要がある。

この変換をRails controllerやUI componentへ散らすと、providerを変えるたびにapplication codeまで変わる。そこで、provider eventとUI protocolの境界を独立させた。

---

## ライブラリの境界

中心にあるのは、provider非依存の2 classである。

```ruby
AgentStream::UIMessage::V1::Event
AgentStream::UIMessage::V1::Stream
```

`Event`はprotocol上の一つのeventを表す。

```ruby
Event = AgentStream::UIMessage::V1::Event

Event.new(:start, message_id: "assistant-1")
Event.new(:text_start, id: "text-1")
Event.new(:text_delta, id: "text-1", delta: "Hello")
Event.new(:text_end, id: "text-1")
```

`Stream`はeventを受け取り、順序を検証し、SSE frameとして出力する。

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new

ui_stream << Event.new(:start)
ui_stream << Event.new(:start_step)
ui_stream << Event.new(:finish_step)
ui_stream << Event.new(:finish, finish_reason: :stop)

ui_stream.each { |frame| puts frame }
```

公開する書き込みinterfaceは`ui_stream << event`だけにした。`Stream`がprovider SDKのclassを直接判定することはない。provider固有の解釈は独立したadapterに置く。

```text
Adapters::OpenAI
Adapters::Anthropic
Adapters::RubyLLM
```

各adapterは`Enumerable<Event>`として振る舞う。

```ruby
adapter.each do |event|
  ui_stream << event
end
```

この形なら、gemが知らないproviderでも同じ境界へ接続できる。

---

## Rails controllerから使う

Railsでは`ActionController::Live`のresponse streamをsinkとして渡す。

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)
    ui_stream.headers.each { |name, value| response.headers[name] = value }

    model.stream(params.require(:prompt)).each do |provider_event|
      ui_stream << AgentStream::UIMessage::V1::Event.new(
        provider_event.type,
        **provider_event.payload,
      )
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("UI message client disconnected")
  ensure
    response.stream.close
  end
end
```

この例ではmodelが返すplain event objectをcontrollerで明示的に`Event`へ変換している。重要なのは、modelが`AgentStream`へ依存する必要がない点である。

```ruby
ProviderEvent = Data.define(:type, :payload)

def stream
  Enumerator.new do |events|
    events << ProviderEvent.new(type: :start, payload: {})
    events << ProviderEvent.new(type: :start_step, payload: {})
    events << ProviderEvent.new(type: :text_start, payload: { id: "text-1" })
    events << ProviderEvent.new(
      type: :text_delta,
      payload: { id: "text-1", delta: "Hello" },
    )
    events << ProviderEvent.new(type: :text_end, payload: { id: "text-1" })
    events << ProviderEvent.new(type: :finish_step, payload: {})
    events << ProviderEvent.new(
      type: :finish,
      payload: { finish_reason: :stop },
    )
  end
end
```

実際のprovider SDKを使う場合は、手書き変換の代わりにadapterを挟む。

```ruby
sdk_stream = openai_client.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: prompt,
)

AgentStream::Adapters::OpenAI.new(sdk_stream).each do |event|
  ui_stream << event
end
```

headerは最初のeventより前に設定し、response streamは`ensure`で閉じる。clientがStopした場合の切断も正常なcontrol flowとして扱う。

---

## RubyLLMのcallbackを接続する

RubyLLMはcallbackでchunkを返すため、`Enumerator`でevent sourceにする。

```ruby
sdk_events = Enumerator.new do |events|
  RubyLLM.chat.ask(prompt) do |chunk|
    events << chunk
  end
end

AgentStream::Adapters::RubyLLM.new(sdk_events).each do |event|
  ui_stream << event
end
```

Agent loopでtool resultもUIへ送りたい場合は、`after_message`などからtool-result messageを同じEnumeratorへ追加する。adapterはtext、thinking、attachment、tool call、tool resultをprotocol eventへ変換する。

---

## AnthropicとOpenAIも同じ形になる

OpenAI:

```ruby
sdk_stream = OpenAI::Client.new.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: prompt,
)

AgentStream::Adapters::OpenAI.new(sdk_stream).each do |event|
  ui_stream << event
end
```

Anthropic:

```ruby
sdk_stream = Anthropic::Client.new.messages.stream(
  model: ENV.fetch("ANTHROPIC_MODEL"),
  max_tokens: 1_024,
  messages: [{ role: :user, content: prompt }],
)

AgentStream::Adapters::Anthropic.new(sdk_stream).each do |event|
  ui_stream << event
end
```

providerごとの差はadapterの内側に残るが、利用側のinterfaceは`adapter.each { |event| ui_stream << event }`で変わらない。

OpenAIやAnthropicのSDKがagent向けの豊富なeventを持っていることを、そのまま利用できる。共通化するためにtextだけへ落とすのではなく、reasoningやtool lifecycleもUI protocolへ写す。

---

## browser側は`useChat`に任せる

React側ではRails endpointを`DefaultChatTransport`へ渡す。

```tsx
import { useChat } from "@ai-sdk/react"
import { DefaultChatTransport } from "ai"

const transport = new DefaultChatTransport({ api: "/chat" })

const {
  messages,
  status,
  error,
  sendMessage,
  stop,
  regenerate,
} = useChat({ transport })
```

`useChat`はSSEを読み、deltaをmessage partsへ蓄積する。

```tsx
{messages.map((message) => (
  <article key={message.id}>
    {message.parts.map((part, index) => {
      if (part.type === "text") {
        return <p key={index}>{part.text}</p>
      }

      if (part.type === "reasoning") {
        return <details key={index}>{part.text}</details>
      }

      return null
    })}
  </article>
))}
```

RailsがReact componentの形を知る必要はない。ReactもOpenAIやAnthropicのevent classを知る必要はない。両者がUI Message Stream Protocolを境界にして接続される。

`useChat`が送るrequest bodyをどうconversationやpromptへ変換するかはapplication側の責務である。このライブラリが扱うのはresponse streamであり、Agentのdomain modelを規定しない。

---

## runtime validationを入れる理由

RBSはadapterを書くときの型情報になる。しかし、providerから来た値はruntime dataであり、RBSだけでは不正なeventを止められない。

そこで`Event.new`は、event type、必須field、未知のfield、field value、JSON compatibilityを検証する。

例えば、`text_delta`に`delta`がない、未知のfieldがある、payloadにJSON化できないobjectが入っている、といった問題はevent生成時に失敗する。

さらに`Stream`はevent間の順序を検証する。

```text
start
  start-step
    text-start
    text-delta
    text-end
  finish-step
finish
```

存在しないpartへのdelta、開始前の終了、同じpartの二重開始、terminal event後の書き込みなどは`ProtocolError`になる。

validationをadapterごとに複製せず、すべての出力が通る`Event`と`Stream`に置く。独自adapterも同じ検証を受ける。

---

## 独自providerを追加する

新しいproviderのために`Stream`を変更する必要はない。provider eventを`Event`へ変換する`Enumerable`を書けばよい。

```ruby
class MyProviderAdapter
  include Enumerable

  def initialize(provider_events)
    @provider_events = provider_events
  end

  def each
    return enum_for(:each) unless block_given?

    yield AgentStream::UIMessage::V1::Event.new(:start)
    yield AgentStream::UIMessage::V1::Event.new(:start_step)

    @provider_events.each do |provider_event|
      # provider_eventをEventへ変換してyieldする
    end

    yield AgentStream::UIMessage::V1::Event.new(:finish_step)
    yield AgentStream::UIMessage::V1::Event.new(
      :finish,
      finish_reason: :stop,
    )
  end
end
```

adapterをgem内へ取り込まなくても、applicationや別gemとして提供できる。`ui_stream << event`に入る時点でprovider非依存になっていればよい。

---

## なぜTurbo Streamsだけにしなかったか

Turbo StreamsでAgent UIを作ることもできる。

```text
Agent event
    ↓
Rails partial
    ↓
Turbo Stream
    ↓
DOM
```

server-rendered HTMLを中心にしたapplicationなら、この方法は十分に良い。text deltaだけならStimulusでSSEを読む実装も小さく作れる。

今回`useChat`を選んだ理由は、Agent UIのstateがtextだけではなかったからである。tool inputの途中状態、tool result、multi-step、abort、retry、errorまで扱うclient runtimeを自作したくなかった。

Reactへ全面移行したかったわけでも、Railsのstreaming機能が不足していたわけでもない。

```text
RailsはAgent backendとして使う
useChatはAgent client runtimeとして使う
protocolで両者をつなぐ
```

この責務分担を選んだ。

---

## fixtureを実形式で検証する

adapter testでは、単純な`Struct`だけをSDK eventに見立てない。

OpenAIとAnthropicは保存した実形式JSONをofficial SDKのmodel converterで復元してからadapterへ渡す。RubyLLMは実際の`Chunk`、`Message`、`ToolCall`、`Thinking` classを構築する。

そのうえで、adapterが返した全eventを本物の`UIMessage::V1::Stream`へ投入する。

```text
official SDK-shaped fixture
          ↓
provider adapter
          ↓
validated Event
          ↓
Stream lifecycle validation
          ↓
SSE frame
```

これにより、fixture上では通るが実SDK objectではmethod名やnestingが違う、というずれを検出しやすくする。

---

## このライブラリがやらないこと

`ruby-ai-stream`はAgent frameworkではない。次の責務はapplicationまたは利用するAgent libraryに残す。

- modelの選択
- conversationの保存
- promptの構築
- toolの実行
- approval policy
- retry
- job化
- 認証と認可
- Railsのthreadやconnection管理

このライブラリの責務は狭い。

```text
provider event
      ↓
common Event
      ↓
UI Message Stream Protocol v1 SSE
```

この境界が狭いから、Rails applicationの設計やAgent loopの実装を固定せずに使える。

---

## まとめ

作りたかったのは、新しいAgent frameworkではない。

RailsでAI Agentを書き、その出力を`useChat`へ自然につなぐためのprotocol boundaryだった。

```ruby
adapter.each do |event|
  ui_stream << event
end
```

provider SDKの違いはadapterが吸収する。eventのschemaは`Event`が守る。stream全体の順序とSSE出力は`Stream`が守る。browser側のAgent stateは`useChat`が扱う。

その結果、Railsの中にあるdomain logicをAgentからそのまま使いながら、client側では既存のAgent UI runtimeを利用できるようになった。
