# Plain model events + Rails streaming server

Rails 8.1 の `ActionController::Live` で、modelが返すplain event objectをUI Message eventへ変換して流すdemoです。Controllerには取得、変換、投入の全体像がそのまま現れます。

```ruby
DemoModel.new.stream(scenario: params.fetch(:scenario, "complete")).each do |provider_event|
  ui_stream << AgentStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
end
```

`DemoModel` は `Data.define(:type, :payload)` で作ったhardcoded eventを `Enumerator` からyieldするだけで、AgentStreamを知りません。実applicationでは `DemoModel#stream` をprovider SDKやagentのevent streamに、変換部分をprovider固有のmappingまたは組み込みadapterに置き換えます。

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

Controllerはheadersを最初のeventより前に設定し、`ensure` で `response.stream` をcloseします。
