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

ブラウザで `http://127.0.0.1:5173/` を開きます。既存DBを既知の4商品へ戻す場合は画面の「デモデータをリセット」を確認して実行します。会話・承認の監査履歴は残り、古い保留承認は無効になります。

「API不要デモ」は既存 `DemoModel` の固定イベントを `/chat/no-llm-call` から再生します。入力による在庫調査は行いません。`/chat` は互換aliasです。どちらもAPI key不要です。

公式SDK `/chat/openai` とRubyLLM `/chat/ruby_llm` は実API経路です。モデルは `gpt-5.6-luna`、reasoningは `medium`。既存initializerがリポジトリルート `.env` の `OPENAI_APIKEY` を読みます。キーをコマンド引数やログに含めないでください。実API呼出しには課金が発生します。

本文送信はボタンのみです。Enter / Shift+Enter / IME確定では送信しません。会話一覧から過去の会話を選択でき、ユーザー発言・回答・ツール結果・承認状態を復元します。「新しい会話」は入力も履歴も空の状態で開始します。入力例はクリックした場合だけ入力され、自動送信されません。会話はサーバーへ保存し、ブラウザのsessionStorageの会話IDとセッショントークンで再読み込み後も復元します。一覧と取得APIは同じブラウザセッションの所有範囲だけを返します。追質問に渡す履歴はサーバー保存分だけです。回答キャッシュはなく、通常の質問と再生成は毎回Agentを実行します。承認ボタンは `addToolApprovalResponse` を呼び、標準の自動HTTP継続で同じassistant/tool callへ結果を返します。承認応答自体はLLMを呼びません。

## 限定検証

```bash
# examples/rails_demo
bin/rails test
# examples/react_client
npm test
npm run build
```

`script/verify_agent.rb openai` / `ruby_llm` は課金を伴う少数ターンの検証です。2026-09-05に両SDKの実APIで調査・追質問・承認登録を確認済みです。

これは認証・課金を備えた製品ではなくローカルデモです。ダッシュボードとresetは共有デモデータを対象にします。

キャッシュ削除は追加migrationで行い、会話・承認・業務データを保持します。`db:reset`は不要です。ルートはRubyLLM 1.16のアダプター互換性テスト、Rails exampleはResponses対応の固定コミットを使用しているため、それぞれのGemfileで検証してください。

「新しい会話」を開いただけでは保存しません。最初の送信時に保存し、未送信の空の会話は履歴に表示しません。サイドバーは最新10件を表示し、「会話一覧を見る」で全件から選べます。既存の空の会話も一覧から除外しますが、保存済みデータは削除しません。
