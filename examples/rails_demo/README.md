# Stockroom AI — Rails inventory SaaS demo

Rails 8.1 / SQLite のデモ在庫管理と、React / AI SDK `useChat` のAIアシスタントです。在庫・販売・仕入条件の通常ダッシュボードとread toolsは同じ業務モデルを使います。補充発注は標準tool approvalの承認後にデモDBへ一度だけ登録します。外部仕入先への送信はありません。

## 起動

リポジトリルートから:

```bash
cd examples/rails_demo
bundle install
bin/rails db:prepare
bin/rails server -b 127.0.0.1 -p 3000
```

別ターミナル:

```bash
cd examples/react_client
npm install
npm run dev -- --host 127.0.0.1
```

ブラウザで `http://127.0.0.1:5173/` を開きます。既存DBを既知の4商品へ戻す場合は画面の「デモデータをリセット」を確認して実行します。会話・承認の監査履歴は残り、古い保留承認とキャッシュは無効になります。

「API不要デモ」は既存 `DemoModel` の固定イベントを `/chat/no-llm-call` から再生します。入力による在庫調査は行いません。`/chat` は互換aliasです。どちらもAPI key不要です。

公式SDK `/chat/openai` とRubyLLM `/chat/ruby_llm` は実API経路です。モデルは `gpt-5.6-luna`、reasoningは `medium`。既存initializerがリポジトリルート `.env` の `OPENAI_APIKEY` を読みます。キーをコマンド引数やログに含めないでください。実API呼出しには課金が発生します。

本文送信はボタンのみです。Enter / Shift+Enter / IME確定では送信しません。会話はサーバーへ保存し、ブラウザのsessionStorageの会話IDとセッショントークンで復元します。承認ボタンは `addToolApprovalResponse` を呼び、標準の自動HTTP継続で同じassistant/tool callへ結果を返します。承認応答自体はLLMを呼びません。

## 限定検証

```bash
# examples/rails_demo
bin/rails test test/controllers/chats_controller_test.rb test/controllers/saas_flow_test.rb test/models/inventory_catalog_test.rb test/models/agent_chat_test.rb
# 非課金のプロセス間cache確認（順に1回ずつ）
bin/rails runner script/verify_cache_persistence.rb write
bin/rails runner script/verify_cache_persistence.rb read
# examples/react_client
npm test
npm run build
```

`script/verify_agent.rb openai` / `ruby_llm` は課金を伴う少数ターンの検証です。今回の実行状況、未達、非課金ブラウザfixtureの証拠は [app-report](../../docs/agent-demo/app-report.md) を参照してください。

これは認証・課金を備えた製品ではなくローカルデモです。ダッシュボードとresetは共有デモデータを対象にします。
