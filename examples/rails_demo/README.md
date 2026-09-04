# Provider-neutral Rails streaming server

Rails 8.1 の `ActionController::Live` から `AIStream::UIMessage::V1::Stream` を直接使う demo です。API key は不要で、`DemoConversation` が deterministic な `Event` を作り、書き込みはすべて `ui_stream << event` を通ります。

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

scenario は `complete`、`abort`、`error`、`slow` です。`../react_client` は `/chat` を port 3000 に proxy し、AI SDK の `useChat` で同じ response を消費します。

実 application では `DemoConversation` を `AIStream::Adapters::OpenAI`、`Anthropic`、`RubyLLM` のいずれかに置き換えます。controller は headers を最初の event より前に設定し、`ensure` で `response.stream` を close します。
