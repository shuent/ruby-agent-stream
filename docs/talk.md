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

textなら、

```ruby
broadcast_append_to(
  conversation,
  target: "message_text",
  html: chunk.content
)
```

tool callなら、

```ruby
broadcast_append_to(
  conversation,
  target: "message_parts",
  partial: "tools/call",
  locals: { tool_call: tool_call }
)
```

tool resultなら、

```ruby
broadcast_replace_to(
  conversation,
  target: dom_id(tool_call),
  partial: "tools/result",
  locals: { tool_call: tool_call }
)
```

reasoningも別のpartialとしてrenderする。

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

概念的にはControllerはこの程度になる。

```ruby
class ChatsController < ApplicationController
  include ActionController::Live

  def create
    stream = RubyLLM::Stream::AISDK.new(response.stream)

    chat = RubyLLM.chat

    chat.ask(prompt) do |chunk|
      stream << chunk
    end

    stream.finish
  rescue ActionController::Live::ClientDisconnected, IOError
    # useChat の stop() で接続が閉じられた
  ensure
    response.stream.close
  end
end
```

細かいHTTP header設定などは必要だが、本質的な処理は、

```ruby
chat.ask(prompt) do |chunk|
  stream << chunk
end
```

だ。

何をやっているのかがそのまま読める。

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

実際にこのadapterからRails経由でSSEを流し、本物の`useChat`へ読ませる検証も行った。

reasoning、text、tool、source、fileなどがmessage partとして組み立てられ、errorではpartial textを残したまま`status: error`になった。clientの`Stop`でもrequestがabortされ、Rails側の処理が途中で終了することを確認できた。

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