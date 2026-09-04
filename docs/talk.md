# RailsでAI Agentを作ると、ChatのStreamingはどこまでRailsらしく書けるのか

RailsでAI Agentを作り始めた。

LLMとのやり取りにはRubyLLMを使う。

```ruby
chat = RubyLLM.chat

chat.ask("Hello") do |chunk|
  puts chunk.content
end
```

OpenAIやAnthropicなどproviderごとのstreaming APIの違いはRubyLLMが吸収してくれる。

では、このstreamをブラウザへ表示するにはどうすればいいのか。

最初は「RailsにはLLM streaming向けの仕組みが足りない」という問題だと思っていた。

でも、実際には少し違った。

---

## 普通のChatなら、Railsはすでにかなり得意

まず、人間同士のChatをRailsで作ることを考える。

ユーザーがメッセージを投稿する。

```ruby
@message = @conversation.messages.create!(message_params)
```

作られたメッセージをTurbo Streamで画面へ追加する。

```ruby
broadcast_append_to(
  @conversation,
  target: "messages",
  partial: "messages/message",
  locals: { message: @message }
)
```

ブラウザ側は、

```erb
<div id="messages">
  <%= render @messages %>
</div>
```

くらいでいい。

新しいメッセージが来るたびにHTMLが追加される。

これはRailsが昔から得意としてきたモデルによく合う。

```text
Messageが作られる
    ↓
HTMLをrenderする
    ↓
Turbo Streamでappendする
```

Chatだから特別なclient-side state machineが必要なわけではない。

**メッセージを積み上げていくだけなら、Rails + Turbo Streamsで十分シンプルに作れる。**

なので、この部分だけを見るとReactを持ち込む理由はあまりない。

---

## LLM Chatで最初に違うのはtext delta

LLM Chatになると、一つだけ大きく違うことがある。

assistant messageが完成してから追加されるのではなく、

```text
Hel
Hello,
Hello, wor
Hello, world
```

のように少しずつ生成される。

RubyLLMではこれがchunkとして返ってくる。

```ruby
chat.ask(prompt) do |chunk|
  chunk.content
end
```

問題は、この`text_delta`をブラウザにどう届けるかだ。

Turbo Streamsは本来、

```text
完成したHTMLをappendする
replaceする
updateする
```

というモデルだ。

一方、LLMから来るのは非常に細かい文字列の断片だ。

もちろんchunkごとにTurbo Streamを送ることもできる。

```ruby
chat.ask(prompt) do |chunk|
  broadcast_append_to(
    conversation,
    target: dom_id(message, :content),
    html: chunk.content
  )
end
```

これでも動く。

ただ、tokenに近い粒度でHTML operationを大量に送るのは少し不自然だ。

そこで、より直接的にやるなら、

```text
ActionController::Live
        +
       SSE
        +
    Stimulus
```

になる。

RailsからHTTP streamとしてdeltaを送り、Stimulus側で受け取ってtextへ追加する。

これなら自然だ。

Railsでは、例えばこう書ける。

```ruby
# config/routes.rb
resource :chat_stream, only: :create

# app/controllers/chat_streams_controller.rb
class ChatStreamsController < ApplicationController
  include ActionController::Live

  def create
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    RubyLLM.chat.ask(params.expect(:prompt)) do |chunk|
      next if chunk.content.blank?

      event = JSON.generate(delta: chunk.content)
      response.stream.write("data: #{event}\n\n")
    end

    response.stream.write("data: [DONE]\n\n")
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("chat stream disconnected")
  ensure
    response.stream.close
  end
end
```

ここでは一つのHTTP responseを閉じずに保ち、RubyLLMのchunkが来るたびにSSEの`data:` frameを書いている。

画面側は普通のRails viewでよい。

```erb
<%= form_with url: chat_stream_path,
      data: {
        controller: "completion",
        action: "submit->completion#submit"
      } do |form| %>
  <%= form.text_field :prompt %>
  <%= form.submit "Send" %>

  <p data-completion-target="output"></p>
<% end %>
```

Stimulus controllerでは`fetch`のresponse bodyを少しずつ読む。

```js
// app/javascript/controllers/completion_controller.js
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

`readSSE`は、HTTP chunkをdecodeし、途中で分かれたSSE frameをつなぐ処理を隠した説明用のhelperだ。ここで見たい本質は、`event.data`からdeltaを取り出し、受信するたびにtextへ追加していることだけである。

ただ、applicationが自分で持つ責務も見えてくる。

```text
HTTP chunkをUTF-8としてdecodeする
SSE frameの途中で分割されたbufferをつなぐ
JSONをparseする
deltaを蓄積する
Stopでfetchをabortする
errorと正常終了を分ける
```

ただしここから、

```js
fetch(...)
response.body
ReadableStream
TextDecoder
AbortController
```

といったclient-side streaming処理を自分で持つことになる。

textだけなら、それでもまだ小さい。

---

# ところが、今のAgentはtextだけではない

ここ数年でLLMアプリに求められるものはかなり増えた。

今のAgent clientが受け取るのは、単なるtext deltaだけではない。

例えば、

```text
text
reasoning

tool call start
tool arguments delta
tool call ready
tool output

approval request

error
finish
abort
```

といったeventがある。

tool callなら、例えば途中では、

```text
tool: lookup_weather

arguments:
{"city":
```

までしか来ていないかもしれない。

次のchunkで、

```text
"Tokyo"}
```

が来て、そこで初めてtool inputが完成する。

reasoningもtextとは別のpartとして扱いたいかもしれない。

toolが実行中なのか、成功したのか、失敗したのかもUIへ反映したい。

つまりclientが扱うものが、

```text
string
```

から、

```text
Agent execution state
```

へ変わってきた。

---

# それでもTurbo Streamsで作ることはできる

ここでTurbo Streamsを否定する必要はない。

むしろRailsらしい解として十分成立する。

例えばserver側でAgent eventを受け取るたびに、それに対応するHTMLを生成する。

説明のため、Agentが次のようなeventを順番に返すとする。

```ruby
{ type: :text, content: "東京の天気を調べます。" }

{
  type: :tool_call,
  id: "call-weather",
  name: "lookup_weather",
  input: { city: "Tokyo" }
}
```

Rails側はeventの`type`を見て、対応するTurbo Streamを送る。

```ruby
agent.run(prompt) do |event|
  case event[:type]
  when :text
    Turbo::StreamsChannel.broadcast_append_to(
      "agent",
      target: "message_text",
      html: ERB::Util.html_escape(event[:content])
    )
  when :tool_call
    Turbo::StreamsChannel.broadcast_append_to(
      "agent",
      target: "message_parts",
      partial: "tools/call",
      locals: { tool_call: event }
    )
  end
end
```

browserは`agent`というstreamを購読し、送られたHTMLを指定された場所へ追加する。

```erb
<%= turbo_stream_from "agent" %>

<section id="message_parts">
  <p id="message_text"></p>
</section>

<%# app/views/tools/_call.html.erb %>
<article id="tool_call_<%= tool_call[:id] %>">
  <strong><%= tool_call[:name] %></strong>
  <span>実行中</span>
</article>
```

tool resultなら同じidの要素を`replace`し、reasoningなら別のpartialを`append`すればよい。

ここではeventの保存場所やAgentを実行する場所を省いている。長時間の処理をActive Jobへ逃すかどうかは運用上の別の判断であり、`event → HTML → DOM`という仕組みそのものにJobは必須ではない。

こうして、

```text
Agent event
    ↓
Rails partial
    ↓
Turbo Stream
    ↓
DOM
```

に変換していけばいい。

これはかなりRailsらしい。

ある意味、**Turbo Streams版の`useChat`**をserver-side renderingで作るようなものだ。

しかも表示するpartを順番に足していくだけなら、それほど複雑でもない。

この方式は一つの正解だと思う。

---

# 問題は「表示」だけではなくなってくること

Agent UIを実際に作っていくと、少しずつ話が変わる。

例えば、

```text
submitted
streaming
ready
error
```

というrequest全体の状態がある。

さらに、

```text
Stop
Retry
Regenerate
```

がある。

tool callには、

```text
input-streaming
input-available
approval-requested
output-available
output-error
```

のような状態がある。

途中でStopされたら、それまでのpartial textは残したい。

Retryでは前のstepを捨てて、新しいstepに差し替えることもある。

そして今後、Agentが高機能になるほど、このclient stateは増えていくはずだ。

Turbo Streamsでもできる。

でも、このあたりまで来ると、

```text
serverが最終HTMLを決めて送る
```

というモデルより、

```text
serverがAgent eventを送る
clientがAgent stateとして解釈する
```

というモデルの方が扱いやすい場面が増えてくる。

---

# ここでAI SDKのuseChatを見た

Node.jsのAI SDKには`useChat`がある。

React側では、

```tsx
const {
  messages,
  status,
  sendMessage,
  stop,
  regenerate,
  error,
} = useChat()
```

くらいでAgent Chatの状態を扱える。

textだけではなく、

- reasoning
- tool calls
- tool results
- error
- abort
- multi-step

といった状態をclient側で管理してくれる。

これを見たとき、

「Railsでも`useChat`相当を作ればいいのでは」

と最初は考えた。

Stimulusで同じものを書く。

でも、それはつまり、

**完成度の高いAgent client runtimeをもう一度自作する**

ということになる。

あまり合理的ではない。

---

# じゃあuseChatだけ使えばいい

そこで発想を変えた。

AI SDKをserver側まで採用する必要はない。

Node.jsへ移行する必要もない。

Next.jsを使う必要もない。

必要なのは、

**client側の`useChat`だけ**

だった。

Agent backendは今まで通りRailsで作る。

LLMとのやり取りもRubyLLMを使う。

```text
Rails
  ↓
RubyLLM
  ↓
???
  ↓
useChat
```

この`???`さえ埋められればいい。

---

# useChatが理解するprotocolをRailsから送ればいい

`useChat`はserverと独自のprivate APIで通信しているわけではない。

AI SDKには、

**UI Message Stream Protocol**

というstream protocolがある。

serverはSSEで、

```text
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

finish
```

といったeventを送る。

`useChat`はそれを読んで、client側の`messages`や`status`を更新している。

なら、

```text
RubyLLM::Chunk
    ↓
AI SDK UI Message Stream Protocol
```

というadapterだけ作ればいい。

これが`RubyLLM::Stream::AISDK`を作った理由だ。

---

# RubyLLM::Stream::AISDK

役割はかなり小さい。

```text
RubyLLM
   ↓
RubyLLM::Chunk
   ↓
RubyLLM::Stream::AISDK
   ↓
AI SDK UI Message Stream Protocol
   ↓
useChat
```

通常のstreamingなら、

```ruby
chat.ask(prompt) do |chunk|
  stream << chunk
end
```

これだけ。

この、

```ruby
stream << chunk
```

が、

```text
RubyLLM content
    → text-delta

RubyLLM thinking
    → reasoning-delta

RubyLLM tool_calls
    → tool-input-*
```

へ変換する。

protocol上必要な、

```text
start
start-step
text-start
text-end
finish-step
finish
[DONE]
```

といった処理もadapter側に閉じ込めた。

application codeはAI SDK protocolを知らなくていい。

---

# Tool callを使っても基本は同じ

tool callをstreamingしている間も、

```ruby
chat.ask(prompt) do |chunk|
  stream << chunk
end
```

は変わらない。

RubyLLMのchunkに含まれるtool call fragmentをadapterが処理する。

toolの実行結果だけは、RubyLLMでは同じchunk blockに戻らないのでcallbackから渡す。

```ruby
chat.after_message do |message|
  stream.write_message(message) if message.tool_result?
end

chat.ask(prompt) do |chunk|
  stream << chunk
end

stream.finish
```

Agentになってもapplication codeに残るのは、

```text
RubyLLMのeventをadapterへ渡す
```

という処理だけだ。

---

# Rails ControllerもAgentの処理が見える

説明のため、Controllerもdata flowだけに絞る。

```ruby
class ChatsController < ApplicationController
  def create
    stream = RubyLLM::Stream::AISDK.new(response.stream)

    chat.ask(user_prompt) do |chunk|
      stream << chunk
    end
  ensure
    response.stream.close
  end
end
```

header設定、requestのparse、tool result、finish、切断・error処理は省いている。ここで見たいのは、RubyLLMのchunkを受け取るたびに`stream << chunk`でadapterへ渡し、最後にHTTP streamを閉じる、という流れだけだ。

---

# HTTP上のdataがuseChatのstateになるまで

ここからは、画面のbuttonを押してから`useChat`のstateが更新されるまでを、対応するコードとHTTP上のdataを並べて追う。

最初の起点はReactの`run("complete")`である。

```tsx
// examples/react_client/src/App.tsx
const {
  messages,
  status,
  sendMessage,
  stop,
} = useChat({
  transport: new DefaultChatTransport({ api: "/chat" }),
})

const run = (scenario) => {
  void sendMessage(
    { text: `Run the ${scenario} RubyLLM stream scenario.` },
    { body: { scenario } },
  )
}

<button onClick={() => run("complete")}>
  Run every event
</button>
```

buttonを押すと`sendMessage`がuser messageを`messages`へ加え、`DefaultChatTransport`が`POST /chat`を送る。第2引数の`body`に渡した`scenario`もrequest bodyへ加わる。

開発環境では、同一originの`/chat`をViteがRailsへproxyしている。

```ts
// examples/react_client/vite.config.ts
proxy: {
  "/chat": "http://127.0.0.1:3000",
}
```

したがって、CDPで見えた次のrequestは突然発生したものではなく、`run("complete")`から呼ばれた`sendMessage`が作ったものだ。`id`、`messages`、`trigger`は`useChat`のtransportが組み立て、`scenario`だけがdemoから追加した値である。

```http
POST http://127.0.0.1:5173/chat
Content-Type: application/json

{
  "scenario": "complete",
  "id": "uGlAokEHyg5owNAC",
  "messages": [
    {
      "id": "42JwlHtzGb3Ea2Mk",
      "role": "user",
      "parts": [
        { "type": "text", "text": "Run the complete RubyLLM stream scenario." }
      ]
    }
  ],
  "trigger": "submit-message"
}
```

Railsのresponseは通常のJSON responseではない。一つのHTTP responseを`chunked`のまま保ち、SSE frameを順番に書く。

```http
HTTP/1.1 200 OK
content-type: text/event-stream
cache-control: no-cache
transfer-encoding: chunked
x-vercel-ai-ui-message-stream: v1
x-accel-buffering: no
```

このrequestでは、bodyに **42個のJSON frame + `[DONE]`** が流れた。抜粋すると次のようになる。

```text
data: {"type":"start","messageId":"rails-demo-assistant-42JwlHtzGb3Ea2Mk","messageMetadata":{"traceId":"rails-fixed-001","phase":"started"}}

data: {"type":"start-step"}

data: {"type":"reasoning-start","id":"reasoning-demo-part-1"}

data: {"type":"reasoning-delta","id":"reasoning-demo-part-1","delta":"Check the request and available tools. "}

data: {"type":"text-start","id":"text-demo-part-2"}

data: {"type":"text-delta","id":"text-demo-part-2","delta":"The RubyLLM chunks are now streaming."}

data: {"type":"tool-input-start","toolCallId":"call-weather","toolName":"lookup_weather"}

data: {"type":"tool-input-delta","toolCallId":"call-weather","inputTextDelta":"{\"city\":\""}

data: {"type":"tool-input-delta","toolCallId":"call-weather","inputTextDelta":"Tokyo\",\"units\":\"celsius\"}"}

data: {"type":"tool-input-available","toolCallId":"call-weather","toolName":"lookup_weather","input":{"city":"Tokyo","units":"celsius"}}

data: {"type":"tool-approval-request","approvalId":"approval-weather","toolCallId":"call-weather"}

data: {"type":"tool-output-available","toolCallId":"call-weather","output":{"city":"Tokyo","celsius":27,"condition":"sunny"}}

data: {"type":"finish","finishReason":"stop","messageMetadata":{"elapsedMs":42}}

data: [DONE]
```

ここで大事なのは、42 frameが42個の画面要素になるわけではないことだ。`useChat`はidとevent typeを使い、streamを一つのmessage stateへ畳み込む。

| wire上のevent | useChatで起きること |
| --- | --- |
| `reasoning-delta`が2回 | 一つの`reasoning` partへ追記し、endで`state: done` |
| `text-delta`が2回 | 一つの`text` partへ追記し、endで`state: done` |
| `tool-input-delta`が2回 | JSON文字列を連結し、`tool-input-available`でobject化 |
| `tool-output-available` | 同じtool partを`state: output-available`へ更新 |
| 同じidの`data-progress`が50、100 | 一つのpartにまとまり、最終値は100 |
| `transient: true`の`data-notice` | messageには保存せず`onData` callbackだけを呼ぶ |
| `reset-step`より前のtext | retry前のstepとして最終messageから取り除く |

最終的なassistant messageは、例えば次のようになる。

```json
{
  "id": "rails-demo-assistant-42JwlHtzGb3Ea2Mk",
  "metadata": {
    "traceId": "rails-fixed-001",
    "phase": "complete",
    "elapsedMs": 42
  },
  "parts": [
    { "type": "step-start" },
    { "type": "reasoning", "state": "done" },
    { "type": "text", "state": "done" },
    { "type": "tool-lookup_weather", "state": "output-available" },
    { "type": "data-progress", "data": { "value": 100, "label": "done" } }
  ]
}
```

terminal eventも、見た目が似ていて意味は異なる。

| 起点 | wire / network | useChatの最終state | partial text |
| --- | --- | --- | --- |
| 正常終了 | `finish` → `[DONE]` | `ready`、`finishReason: stop` | 完成したtextを保持 |
| server error | `error` → `[DONE]` | `error`、`isError: true` | `A partial answer survives.`を保持 |
| server abort | `abort` → `[DONE]` | `ready`、このversionでは`isAbort: false` | serverが送ったtextを保持 |
| clientのStop | browserがrequestをcancel | `ready`、`isAbort: true` | 受信済み6 tokenを保持 |

clientのStopでは、CDP上のrequestは開始から約0.89秒で`net::ERR_ABORTED`になった。Rails側ではsocket切断を受けて`AI SDK client disconnected`となり、約1.2秒で処理を終えた。100 tokenを生成するslow runは、`token-0`から`token-5`までを画面に残して中断された。

つまりStopは「serverからabort eventを受信した」ことではない。browserの`AbortController`がHTTP request自体を閉じ、その結果がRailsの`ClientDisconnected`まで逆向きに伝播する。

---

# ClientはuseChatに任せる

React側は、

```tsx
const {
  messages,
  status,
  sendMessage,
  stop,
  regenerate,
  error,
} = useChat({
  transport: new DefaultChatTransport({
    api: "/chat",
  }),
})
```

だけ。

自分で、

```text
SSE parser
delta accumulator
tool-call reducer
abort state
error state
```

を書く必要はない。

上のwire dataに含まれるreasoning、text、tool、source、fileなどを、`useChat`がmessage partへ組み立てる。application codeが書くのは、その最終stateをどう見せるかだけになる。

---

# Reactへ移行したかったわけではない

今回の結論は、

「Agentを作るならRailsをやめてReactにしよう」

ではない。

むしろ逆だ。

普通のWeb UIはRailsで作る。

```text
CRUD
navigation
forms
ordinary partial updates
```

はTurboでいい。

Chatのmessageを積み上げるだけでもTurboでいい。

ただし、

```text
LLM / Agent streaming state
```

だけはclient runtimeを持つ価値が大きい。

だからそこだけ`useChat`を使う。

最終的には、

```text
                   Rails application

通常のinteraction                  Agent streaming
────────────────                  ───────────────

Rails                              Rails
  ↓                                  ↓
Turbo                              RubyLLM
  ↓                                  ↓
HTML                               AISDK adapter
                                     ↓
                                   useChat
                                     ↓
                                 React island
```

という構成にした。

---

# Turbo Streams版も一つの正解

今回、Turbo StreamsでAgent clientを作る案を捨てたわけではない。

serverでeventをHTMLへ変換して、

```text
text
reasoning
tool call
tool result
```

を順番にappend / replaceしていく。

Railsだけで閉じるので、これは十分魅力的だ。

特に、

```text
Agentの出力を表示するだけ
```

ならかなりシンプルに作れると思う。

ただ、今回作ろうとしていたAgentでは、

```text
stop
abort
retry
multi-step
tool state
error recovery
```

までclient側で扱いたかった。

さらにAgent clientは今後も高機能化していく可能性が高い。

そこまで自分で追いかけるより、

**Agent clientとして成熟している`useChat`を使う方が合理的**

と判断した。

---

# 足りなかったのはRailsのstreaming機能ではなかった

振り返ると、Railsには必要な部品の多くが最初からあった。

HTTP streamはできる。

Turbo Streamsもある。

RubyLLMはprovider streamingを抽象化してくれる。

足りなかったのは、その間にある一層だった。

```text
RubyLLMのstream
        ↓
clientが理解できるAgent event stream
```

そこを、

```text
AI SDK UI Message Stream Protocol
```

でつないだ。

そしてapplication codeでは、

```ruby
chat.ask(prompt) do |chunk|
  stream << chunk
end
```

まで小さくできた。

今回作ったものはAgent frameworkではない。

Rails用の`useChat`でもない。

**Rails + RubyLLMで作ったAgent backendを、既存の高機能なAgent clientへつなぐadapter**

である。

普通のWeb interactionはRailsらしくTurboで。

複雑なAgent streamingだけは、`useChat`に任せる。

その境界が、自分にとって一番シンプルだった。
