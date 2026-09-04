# OpenAI adapter + Rails streaming server

Rails 8.1 の `ActionController::Live` で、provider SDK event をadapter経由で `AIStream::UIMessage::V1::Stream` へ流すdemoです。Controllerには変換の全体像がそのまま現れます。

```ruby
provider_events = get_from_model
AIStream::Adapters::OpenAI.new(provider_events).each do |event|
  ui_stream << event
end
```

API keyなしで動かせるよう、`DemoModel` はrepositoryのfixtureを実際のopenai-ruby event modelへdecodeして返します。実applicationでは `get_from_model` を次のようなSDK呼び出しに置き換えます。

```ruby
OpenAI::Client.new.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: params.require(:message)
)
```

```bash
bundle install
bin/rails test
bin/rails server -b 127.0.0.1 -p 3000
```

raw protocol の確認:

```bash
curl -N -X POST \
  -H 'Content-Type: application/json' \
  --data '{"scenario":"complete"}' \
  http://127.0.0.1:3000/chat
```

scenario は `complete`、`error`、`slow` です。`../react_client` は `/chat` を port 3000 に proxy し、AI SDK の `useChat` で同じ response を消費します。

AnthropicやRubyLLMを使う場合も、`get_from_model` とadapter classだけを交換します。Controllerはheadersを最初のeventより前に設定し、`ensure` で `response.stream` をcloseします。
