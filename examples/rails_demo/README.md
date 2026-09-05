# Stockroom AI — Rails inventory SaaS demo

Rails 8.1 / SQLite のデモ在庫管理と、React / AI SDK `useChat` のAIアシスタントです。在庫・販売・仕入条件の通常ダッシュボードとread toolsは同じ業務モデルを使います。補充発注は標準tool approvalの承認後にデモDBへ一度だけ登録します。外部仕入先への送信はありません。

## 起動

リポジトリルートから:

```bash
bin/dev
```

Ruby（`.ruby-version`に記載）とNode.js / npmが必要です。Rails側の`bin/dev`が起動処理を所有し、ルートの`bin/dev`はそこへ委譲します。`cd examples/rails_demo`後の`bin/dev`でも同じ動作です。Foreman等の追加ツールは不要です。

初回は不足しているGemとnpm依存をインストールし、`db:prepare`でDBを準備してRails（3000）とVite（5173）を起動します。既存DBはリセットしません。Ctrl-Cで両方停止し、片方が終了した場合ももう片方を停止します。ポートが使用中なら起動前にエラーを表示します。依存のlockfileを更新した場合は、それぞれのディレクトリで`bundle install` / `npm ci`を実行してください。

Railsだけを起動する場合は従来どおり`bin/rails server -b 127.0.0.1 -p 3000`、Reactだけなら`examples/react_client`で`npm run dev`です。

ブラウザで `http://127.0.0.1:5173/` を開きます。既存DBを既知の4商品へ戻す場合は画面の「デモデータをリセット」を確認して実行します。会話・承認の監査履歴は残り、古い保留承認とキャッシュは無効になります。

「API不要デモ」は既存 `DemoModel` の固定イベントを `/chat/no-llm-call` から再生します。入力による在庫調査は行いません。`/chat` は互換aliasです。どちらもAPI key不要です。

公式SDK `/chat/openai` とRubyLLM `/chat/ruby_llm` は実API経路です。モデルは `gpt-5.6-luna`、reasoningは `medium`。既存initializerがリポジトリルート `.env` の `OPENAI_APIKEY` を読みます。キーをコマンド引数やログに含めないでください。実API呼出しには課金が発生します。

本文送信はボタンのみです。Enter / Shift+Enter / IME確定では送信しません。会話はサーバーへ保存し、ブラウザのsessionStorageの会話IDとセッショントークンで復元します。承認ボタンは `addToolApprovalResponse` を呼び、標準の自動HTTP継続で同じassistant/tool callへ結果を返します。承認応答自体はLLMを呼びません。

## 限定検証

```bash
# examples/rails_demo
bin/rails test test/controllers/chats_controller_test.rb test/controllers/saas_flow_test.rb test/models/inventory_catalog_test.rb test/models/agent_chat_test.rb test/models/agent_runners_test.rb
# 非課金のプロセス間cache確認（順に1回ずつ）
bin/rails runner script/verify_cache_persistence.rb write
bin/rails runner script/verify_cache_persistence.rb read
# examples/react_client
npm test
npm run build
```

`script/verify_agent.rb openai` / `ruby_llm` は課金を伴う少数ターンの検証です。2026-09-05に両SDKの実APIで調査・追質問・承認登録を確認済みです。今回の修正・取得結果は [app-report](../../docs/agent-demo/app-report.md) を参照してください。

これは認証・課金を備えた製品ではなくローカルデモです。ダッシュボードとresetは共有デモデータを対象にします。
