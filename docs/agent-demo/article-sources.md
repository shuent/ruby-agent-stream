# 記事の参照資料

取得日はすべて 2026-09-05。記事本文に採用する主張と、確認した根拠を記録する。

## 公開資料

| 資料 | 確認した内容 | 記事での用途 |
| --- | --- | --- |
| [前回の記事: AI AgentはRailsで作りたいが、ai-sdk useChatに表示は任せたい人へ](https://zenn.dev/shuent/articles/e0c159cd2989f9) | ブラウザで本文を通読。Railsにagent、tool、業務処理を残し、provider adapter、共通Event、UI Message Streamを介して`useChat`へ渡す構成。前回はライブラリ紹介と境界設計が中心 | 続編であることの明示。ライブラリ内部の重複説明を避け、今回の実アプリへ接続 |
| [OpenAI Function calling](https://developers.openai.com/api/docs/guides/function-calling) | アプリがtoolを定義し、モデルのfunction callを実行し、`function_call_output`を次の入力へ返すフロー。reasoning itemをtool出力とともに戻す注意 | Rails側agent loopの説明 |
| [OpenAI Reasoning models](https://developers.openai.com/api/docs/guides/reasoning) | reasoning effortの意味。raw reasoning tokenはAPIに公開されず、summaryを要求できる | `medium`の説明とraw state表示の限界 |
| [OpenAI GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) | Responses、streaming、function calling、structured outputsをサポート。reasoning effortは`none`、`low`、`medium`、`high`、`xhigh`、`max` | 採用モデルと設定の根拠 |
| [AI SDK Generative User Interfaces](https://ai-sdk.dev/docs/ai-sdk-ui/generative-user-interfaces) | tool result dataをReact componentに対応付ける流れ。tool partの状態に応じて表示を変える例 | 補充カードとtool状態表示の説明 |
| [AI SDK useChat](https://ai-sdk.dev/docs/reference/ai-sdk-ui/use-chat) | streamed message/stateの管理、message `parts`、status、send/regenerate/stop | 同一UI、composer、再生成の説明 |

## リポジトリ内資料

| 資料 | 確認した内容 | 記事での用途 |
| --- | --- | --- |
| `README.ja.md` | 共通Event/StreamとOpenAI、RubyLLM adapterの責務。会話管理、tool実行、永続化などはライブラリの対象外 | ライブラリとRailsアプリの責務分担 |
| `lib/ai_stream/adapters/openai.rb` | OpenAI Responses streamのtext、reasoning、function call等から共通Eventへの変換 | 実装説明の確認。記事への抜粋予定なし |
| `lib/ai_stream/adapters/ruby_llm.rb` | RubyLLM chunkとtool resultを共通Eventへ変換 | 実装説明の確認。記事への抜粋予定なし |
| `docs/agent-demo/lib-requests/LIB-001.md` | OpenAI adapterの`lifecycle: :content`、列挙後の`response`/`finish_reason`公開。アプリがmulti-step lifecycleを所有するための修正 | 「実際にmulti-stepで使って見つかった不足」のOpenAI側 |
| `docs/agent-demo/lib-requests/LIB-002.md` | RubyLLMのcompletion間でtool stream keyが再利用される問題、step境界での状態reset、usage合算 | 同節のRubyLLM側 |

## 実装・証跡の受領待ち

以下はファイルと動作が確定してから追記する。

- OpenAI公式SDK endpointとagent loopの引用元
- RubyLLM endpointとagent loopの引用元
- 共通toolの正確な名前と定義元
- ReactのGenerative UI、prompt template、raw detailsの引用元
- SQLite cache key、成功完了のみ保存、regenerate bypassの引用元
- 再現コマンドの出典
- 実API run IDと証跡ファイル
- 実ブラウザGIFと対応run ID
- `lib_fixes`担当の最終reportと修正後の制約

## 扱いに関する注意

- `.env`の秘密値は参照、転記しない。
- デモのseedデータを実業務データとして説明しない。
- アプリ側のSQLite永続結果キャッシュを、OpenAI APIのprompt cachingとして説明しない。
- キャッシュ再生をlive API実行として説明しない。
- 実行結果と画面は、保存済み証跡に対応するものだけを記事へ掲載する。

## 再開後の参照（2026-09-05）

旧記録は前担当の読了記録として保持。競合する旧検証マトリクスより`resume-brief.md`を優先する。

| 資料 | 確認した内容 | 記事での用途 |
| --- | --- | --- |
| `docs/agent-demo/resume-brief.md` / `redispatch.md` | SaaS dashboardとAIの共通業務操作、承認付きwrite、会話、deterministic、cache/reset、証跡はapp担当から受領する範囲 | 今回の記事構成・未達の判断 |
| [OpenAI Function calling](https://developers.openai.com/api/docs/guides/function-calling) | 再開後に公式検索とページ取得。アプリがtoolを公開し、モデルの呼び出しに結果を戻す契約 | agent loopの短い説明 |
| [AI SDK Chatbot Tool Usage](https://ai-sdk.dev/docs/ai-sdk-ui/chatbot-tool-usage) | 検索では承認状態と自動続行APIを確認。ページ本文取得はwebツールのUnsupported content-typeで失敗し、以下のinstalled sourceで契約を確認した | 標準tool approvalへのリンク。本文取得済みとは扱わない |
| `examples/react_client/node_modules/ai/src/ui/chat.ts` | `addToolApprovalResponse`が同じapproval IDのpartを`approval-responded`へ変更。非streaming時に`sendAutomaticallyWhen`を確認して次requestを送る | useChatとbackendの分担 |
| `examples/react_client/node_modules/ai/src/ui/last-assistant-message-is-complete-with-approval-responses.ts` | 最後のassistant stepに承認応答があり、toolが応答済み/完了状態なら自動続行可能 | 承認と本文の送信ボタンの区別 |
| `examples/rails_demo/app/models/inventory_catalog.rb` | read操作、30日販売実績・利用可能在庫・MOQ・入数による補充計算 | 計算部分の実コード抜粋 |

アプリとlibの確定コード・自己検証報告は受領後、以下へ対応を追記する。記事担当はアプリ/APIを実行せず、証跡の追加検証をしない。

### lib担当からの再開後共有

- `lib/ai_stream/ui_message/v1/stream.rb`: `continuation:`は保存Event列でprotocolのtool/approval状態を復元する。履歴SSEを再送しない。
- `test/integration/approval_continuation.mjs` / `approval_frames.rb`: installed `ai` 7.0.92 / `@ai-sdk/react` 4.0.95のChatとDefaultChatTransportにRuby SSEを渡す、fake HTTPの承認・拒否再現。lib担当が各2HTTP・assistant1・tool1を報告。実API検証ではない。
- `docs/agent-demo/lib-requests/APP-001.md`: 1.16.0は対象モデルのtools + reasoning条件でChat Completions endpointが阻害。開発版Responses契約の採用はSDK側の対応であり、libのイベント変換修正とは別。
- `docs/agent-demo/lib-report.md`: 停止前のOpenAI lifecycleとRubyLLM step/key/usage変更は旧自己検証報告を保持して再利用。記事担当はtestを再実行しない。

### app確定コードの受領（live証跡は別）

`/root/saas_app`の確定通知後に以下をread-onlyで読んだ。動作を独立実行したものではない。

| 引用/説明 | 出典 |
| --- | --- |
| dashboard/read/発注登録、数量検証、revision | `examples/rails_demo/app/models/inventory_catalog.rb` |
| useChat初期履歴、標準approval helper/ボタン、dashboard再取得 | `examples/react_client/src/App.tsx` |
| 公開操作とX-Demo-Session | `examples/react_client/src/domain.ts` |
| exact input/会話/assistant/tool binding、冪等判断、stale拒否 | `examples/rails_demo/app/models/agent_approval.rb` |
| server履歴保存とセッションdigest、reload復元 | `examples/rails_demo/app/models/agent_conversation.rb` |
| 次ターン文脈のJSON文字列化、共通approval result、cache除外 | `examples/rails_demo/app/models/agent_chat.rb` |
| Responses loopと手動write待機 | `examples/rails_demo/app/models/openai_agent_runner.rb` |
| RubyLLM Responses/thinking、SDKのapproval待機を永続承認へ接続 | `examples/rails_demo/app/models/ruby_llm_agent_runner.rb`、`create_replenishment_order_tool.rb` |
| Stream continuation、session lookup | `examples/rails_demo/app/controllers/chats_controller.rb` |
| digest、write/resetによるcache失効 | `examples/rails_demo/app/models/agent_cache_key.rb`、`demo_revision.rb`、`demo_inventory.rb` |
| approval IDに対するorderのunique index | `examples/rails_demo/db/migrate/20260905061902_add_saas_agent_state.rb` |

承認直後はLLMを再呼び出しせずRailsの定型結果を返す実装。次ターンにSDK固有会話objectをそのまま復元する実装とも異なるため、本文に明記した。

### 取得済みapp証跡と最終採用

- `docs/agent-demo/app-report.md`の最終報告を受領。
- `evidence/rails-real-agent/verification-summary.json`から非課金browserの登録結果、test件数、cacheの別process確認を転記。
- `images/rails-real-agent/non-billing-approval.gif`を本文へ掲載。4実スクリーンショット各2.2秒の構成。承認提案は非課金fixture、実local HTTP/SQLiteで登録する範囲の証跡。live生成GIFとは扱わない。
- 実APIは自動承認審査で未実行。設定値と実応答を分離し、live run ID、モデルの成功回答、reasoning観測を掲載していない。
- 起動節は更新済み`examples/rails_demo/README.md`とapp-reportに対応。
- 各実コード/結果/GIFの細かい対応・未達・自己照合結果は`article-report.md`の再開後最終報告へ集約。
