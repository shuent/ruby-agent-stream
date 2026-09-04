# RailsでAI Agentを書き、`useChat`で表示する

## 結論

RailsでAI Agentを書き、そのstreaming UIをAI SDKの`useChat`で扱えるようにするため、Rubyのprovider SDK eventを [AI SDK UI Message Stream Protocol v1](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol) に変換する`ruby-agent-stream`を作った。

実務での形を先に書くと、Rails controllerはAgentのeventをUI streamへ流す。

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)
    ui_stream.headers.each { |name, value| response.headers[name] = value }

    sdk_events = MyRubyAgent.new.stream(params.require(:prompt))
    AgentStream::Adapters::RubyLLM.new(sdk_events).each do |event|
      ui_stream << event
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("chat stream disconnected")
  ensure
    response.stream.close
  end
end
```

ここで`MyRubyAgent#stream`は、application側のAgentがRubyLLMのchunkを`Enumerator`として返す擬似的なinterfaceである。OpenAIやAnthropicを直接使う場合はadapterだけを差し替える。

React側はRails endpointを`useChat`へ渡す。表示用のJSXを除けば、必要なclient codeはこの程度になる。

```ts
import { useChat } from "@ai-sdk/react"
import { DefaultChatTransport } from "ai"

const chat = useChat({
  transport: new DefaultChatTransport({ api: "/chat" }),
})

chat.sendMessage(
  { text: prompt },
  { body: { prompt } },
)

chat.messages
chat.status
chat.stop()
chat.regenerate()
```

RailsはAgent、tool、DB、認可を担当し続ける。`useChat`はtext、reasoning、tool call、停止、エラーなどのclient stateを担当する。その間をprotocolでつなぐ。

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

## なぜRailsでAgentを書きたかったのか

実務的な出発点は、Rails applicationの中にAI Agentを書きたかったことだった。

既存のRails applicationには、すでにAgentが使いたい資産がある。

- Active Recordのデータ
- 認証と認可
- domain service
- background job
- mailerやnotification
- 社内APIや外部serviceとのintegration
- audit log

Agentがこれらをtoolとして使うなら、AgentもRailsに置くのが自然である。LLMを使うためだけにserverをNode.jsへ分離すると、domain logicや権限境界を二重に持つことになりやすい。

一方、browser側のAgent UIは自作したくなかった。

text deltaの表示だけなら小さい。しかしAgentになると、reasoning、tool input、tool result、multi-step、stop、retry、errorとstateが増える。この部分には、すでにAI SDKの`useChat`がある。

欲しかったのはNode.js backendではなく、`useChat`というclient runtimeだった。

```text
backend: Rails
agent: Ruby
client state: useChat
```

その組み合わせに必要なのが、Rubyのevent streamとUI Message Stream Protocolの間の変換だった。

---

## 最初はRubyLLM専用で作ろうとした

最初に考えたinterfaceは、RubyLLMのchunkを直接受け取る専用streamだった。

```ruby
stream = RubyLLM::Stream::AISDK.new(response.stream)

RubyLLM.chat.ask(prompt) do |chunk|
  stream << chunk
end
```

これは一見かなり簡単だった。RubyLLMがproviderごとの差を吸収し、こちらは`RubyLLM::Chunk`だけをUI protocolへ変換すればよい。

ただし、この設計ではstream本体がRubyLLMのclassとevent semanticsを知ることになる。

```text
RubyLLM::Chunk
      ↓
RubyLLM専用Stream
      ↓
UI protocol
```

OpenAIやAnthropicのofficial SDKも、現在はtextだけでなくreasoning、tool call、usage、完了、失敗などの豊富なeventを返す。applicationがそれらを直接使いたくなったとき、RubyLLM専用streamでは接続できない。

providerが増えるたびにstream側へ次のような分岐を足すことも考えられる。

```ruby
case event
when RubyLLM::Chunk
  # ...
when OpenAI::Responses::Event
  # ...
when Anthropic::RawMessageStreamEvent
  # ...
end
```

しかし、これはUI protocolを出力するclassがprovider SDKの都合を抱える設計になる。

そこで、streamへ入る直前の形をprovider非依存の`Event`に統一した。

```ruby
event = AgentStream::UIMessage::V1::Event.new(
  :text_delta,
  id: "text-1",
  delta: "Hello",
)

ui_stream << event
```

provider固有のeventを`Event`へ変換する部分だけを、小さなadapterとして外へ出した。

```text
OpenAI event ──── OpenAI adapter ────┐
Anthropic event ─ Anthropic adapter ─┼─ Event ─ Stream ─ SSE
RubyLLM chunk ─── RubyLLM adapter ───┘
```

この変更で、`Stream`はprovider SDKを何も知らなくなった。adapterは`Enumerable<Event>`、streamの入力は`ui_stream << event`という単純な境界になった。

RubyLLM依存を捨てたというより、RubyLLMを三つある入力の一つにした。最初の実装を一段抽象化したことで、OpenAI、Anthropic、RubyLLMを同じinterfaceで扱えるようになった。

```ruby
AgentStream::Adapters::OpenAI.new(openai_events)
AgentStream::Adapters::Anthropic.new(anthropic_events)
AgentStream::Adapters::RubyLLM.new(ruby_llm_events)
```

それぞれを`.each { |event| ui_stream << event }`で接続できる。providerごとの詳しい対応eventや使い方は[README](../README.ja.md)に置き、ここではこの境界だけを重要な設計として扱う。

---

## textだけならRailsらしい実装で十分

`useChat`を使わなくても、RailsからLLMのstreamを表示することはできる。特にtext deltaだけなら実装は小さい。

### Turbo Streamsでchunkをappendする

assistant messageの本文をtargetにして、chunkごとにHTMLをappendする。

```ruby
assistant_message = conversation.messages.create!(role: :assistant)

RubyLLM.chat.ask(prompt) do |chunk|
  next if chunk.content.blank?

  Turbo::StreamsChannel.broadcast_append_to(
    conversation,
    target: dom_id(assistant_message, :content),
    html: ERB::Util.html_escape(chunk.content),
  )
end
```

viewは通常のTurbo Streamを購読する。

```erb
<%= turbo_stream_from conversation %>

<article id="<%= dom_id(assistant_message) %>">
  <div id="<%= dom_id(assistant_message, :content) %>"></div>
</article>
```

```text
LLM chunk
    ↓
Turbo Stream append
    ↓
assistant messageのDOM
```

server-rendered HTMLを中心にしたapplicationなら、この方法は十分に良い。tool callもRails partialとして描画し、同じIDを`replace`して状態を進める設計にできる。

### SSEでtext deltaを送り、Stimulusでappendする

HTML operationではなくtext deltaを送りたいなら、RailsのHTTP responseをSSEとしてstreamする。

```ruby
class CompletionsController < ApplicationController
  include ActionController::Live

  def create
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    RubyLLM.chat.ask(params.require(:prompt)) do |chunk|
      next if chunk.content.blank?

      data = JSON.generate(delta: chunk.content)
      response.stream.write("data: #{data}\n\n")
    end

    response.stream.write("data: [DONE]\n\n")
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("completion stream disconnected")
  ensure
    response.stream.close
  end
end
```

Rails viewはStimulus controllerへformと出力先を渡す。

```erb
<%= form_with url: completions_path,
      data: {
        controller: "completion",
        action: "submit->completion#submit",
      } do |form| %>
  <%= form.text_field :prompt %>
  <%= form.submit "Send" %>
  <p data-completion-target="output"></p>
<% end %>
```

Stimulus側ではresponse bodyからSSEを読み、deltaを追加する。

```js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["output"]

  async submit(event) {
    event.preventDefault()
    this.outputTarget.textContent = ""

    const response = await fetch(this.element.action, {
      method: "POST",
      body: new FormData(this.element),
      headers: { Accept: "text/event-stream" },
    })

    for await (const event of readSSE(response.body)) {
      if (event.data === "[DONE]") break

      const { delta } = JSON.parse(event.data)
      this.outputTarget.append(delta)
    }
  }
}
```

ここで`readSSE`は、HTTP chunkのdecode、途中で分割されたSSE frameの結合、`data:`行の取り出しを隠した説明用helperである。

この二つはどちらもRailsらしい解であり、text streamingだけなら十分実用になる。

---

## Agentになるとclient stateが増える

今回`useChat`を使いたかった理由は、表示するものがtextだけで終わらなかったからである。

```text
text
reasoning
tool input streaming
tool input available
tool output
approval
multi-step
finish
abort
error
```

tool argumentsは一度に完成せず、JSON文字列のdeltaとして届くことがある。toolが入力中なのか、実行可能なのか、結果を得たのかもUI stateになる。

request全体にも`submitted`、`streaming`、`ready`、`error`があり、StopやRegenerateでは途中までのmessageをどう扱うか決める必要がある。

Turbo StreamsやStimulusでも作れる。しかし、この段階では単なるstream表示ではなく、Agent client runtimeを作る仕事になる。

AI SDKの`useChat`は、UI Message Stream Protocolを受け取ってこのstateを`messages`とmessage partsへ組み立てる。そこでclient-side state machineは`useChat`へ任せ、Railsはprotocol eventを返すことにした。

```text
provider event
      ↓ adapter
UI Message Event
      ↓ Stream
SSE frame
      ↓ useChat
messages / status / tool state
```

`ruby-agent-stream`が行うのは、この中央の変換とSSE出力である。

---

## RailsとReactの責務は混ざらない

`useChat`を使うことは、Agent backendをJavaScriptへ移すことではない。

Rails側には、次の責務が残る。

- conversationを読み書きする
- current userの権限を確認する
- promptやcontextを組み立てる
- Agentとtoolを実行する
- toolからActive Recordやdomain serviceを使う
- 必要なら実行履歴を保存する

React側は、streamから得たmessage partsを表示し、送信、停止、再生成などの操作を提供する。

両者の間にあるのはprovider固有eventではなく、UI Message Stream Protocolである。RailsはReact componentを知らず、ReactはRubyLLM、OpenAI、Anthropicのclassを知らない。

また、このライブラリは`useChat`が送るrequest bodyの解釈を規定しない。最新のuser messageをどう取り出し、conversationへ保存し、Agentへ渡すかはapplicationごとに決められる。

---

## 最終的なinterface

設計をRubyLLM専用streamからprovider-agnosticなevent streamへ書き直した結果、公開interfaceは小さくなった。

```ruby
ui_stream << event
```

provider adapterはeventをyieldする。

```ruby
adapter.each do |event|
  ui_stream << event
end
```

Rails responseへ即時に書く場合はsinkを渡す。

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream)
```

testやRack bodyとして扱う場合はsinkを省略できる。

```ruby
ui_stream = AgentStream::UIMessage::V1::Stream.new
ui_stream << event
ui_stream.each { |sse_frame| consume(sse_frame) }
```

細かなevent一覧、providerごとの変換範囲、RBS、エラー、実行可能なexampleは[README](../README.ja.md)に置いている。この文章で伝えたいのは、なぜこの境界を作り、どう分離したかである。

---

## まとめ

出発点は、RailsでAI Agentを書きながら、browserでは`useChat`を使いたいという実務上の要求だった。

最初はRubyLLMのchunkを直接受ける専用streamを考えた。しかし、UI protocolへ入るeventを共通化すれば、RubyLLMは特別な存在ではなく、小さなadapterの一つになる。

同じ方法でOpenAIとAnthropicのofficial SDK eventも接続できる。

```text
RailsのdomainとAgent
        ↓
provider adapter
        ↓
AgentStream Event / Stream
        ↓
AI SDK useChat
```

textだけならTurbo StreamsやSSE + Stimulusでも自然に書ける。Agent UIのstateが増えたときは`useChat`へ任せられる。

Railsらしいbackendを保ちながら、既存のAgent client runtimeを利用する。そのための薄いprotocol boundaryが`ruby-agent-stream`である。
