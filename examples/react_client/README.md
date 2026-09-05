# Stockroom AI — React client

Railsの在庫管理デモを、ダッシュボードと`@ai-sdk/react`の`useChat`から操作します。ストリームの独自parserやmessage reducerは持ちません。

リポジトリルートで`bin/dev`を実行すると、RailsとViteがまとめて起動します。http://127.0.0.1:5173/ を開いてください。Ctrl-Cで両方停止します。API設定は[Rails側のREADME](../rails_demo/README.md)を参照してください。

React側だけを起動・検証する場合:

```bash
# examples/react_client
npm ci
npm test
npm run build
npm run dev
```

公式OpenAI SDK、RubyLLM、API不要デモを切り替えられます。本文は送信ボタンだけで送信し、承認ボタンはAI SDK標準の承認応答を送ります。`data-testid`でブラウザ検証の対象を識別できます。
