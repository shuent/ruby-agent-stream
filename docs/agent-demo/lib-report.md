# Library担当報告

状態: 再開後のlibrary作業・初回app統合連絡完了（詳細は末尾）。旧担当記録は保持。

## 変更概要

- OpenAI Responses adapterへ `lifecycle: :message | :step | :content` を追加した。既定の `:message` は従来どおり1 provider responseを完全なUI messageとして終端する。
- `:content` はprovider由来のcontent/tool input/reasoningと完了時の `message-metadata` だけを出す。アプリは同じUI message内でstep境界、tool実行、tool output、次provider request、最終 `finish` を所有できる。
- OpenAI adapterは列挙後に完了SDK responseを `response`、変換済み終了理由を `finish_reason` で公開する。Response streamを再列挙せず `previous_response_id` を取得できる。
- RubyLLM adapterはtool-result Message後の最初のchunkで新しいUI stepを始める。step切替時にprovider completion内だけで有効なtool stream keyとpart IDをresetし、異なるtoolがkey `0` を再利用できるようにした。
- RubyLLMのusageは各provider completionの最終snapshotをtool loop全体で合算する。
- RBS、英日README、CHANGELOGを公開挙動に合わせた。

provider-neutralな `Event` → `Stream` の責務は維持した。tool実行、業務データ、cache、Responses requestの再構築はアプリ側に残した。

## 対応issue

- [LIB-001: OpenAI Responses adapterが1回目でUI messageを終端する](lib-requests/LIB-001.md) — fixed
- [LIB-002: RubyLLMの自動tool loopでstream key再利用が衝突する](lib-requests/LIB-002.md) — fixed
- APP依頼票: 現時点でなし（app担当の初回統合完了確認待ち）

## 調査根拠

- OpenAI公式function calling guideのRuby例は、tool結果を `function_call_output` として渡し、`previous_response_id` で前responseへ接続する: https://developers.openai.com/api/docs/guides/function-calling
- OpenAI Responses create referenceでは、`previous_response_id` 使用時も前responseのinstructionsは引き継がれないため再送が必要: https://developers.openai.com/api/reference/resources/responses/methods/create
- `gpt-5.6-luna` はResponses、streaming、function callingをサポートする: https://developers.openai.com/api/docs/models/gpt-5.6-luna
- installed `openai` 0.85.0で `Responses#stream` の `previous_response_id` / `FunctionCallOutput` input型、completed event、response usage、reasoning summary event modelを確認した。
- installed `ruby_llm` 1.16.0の `Chat#complete_once` / `handle_tool_calls` / `add_tool_result_message` を確認した。streaming blockは再帰したprovider completionへ再利用され、`after_message` はassistant Messageと各tool-result Messageで呼ばれる。tool-resultだけをadapterへ渡すには `message.tool_result?` でfilterする。

`.env` / `.env.swp` は読まず、変更していない。実APIの課金検証はapp担当へ集約した。

## 変更ファイル

- `lib/ai_stream/adapters.rb`
- `lib/ai_stream/adapters/openai.rb`
- `lib/ai_stream/adapters/ruby_llm.rb`
- `test/ai_stream/adapters/test_openai.rb`
- `test/ai_stream/adapters/test_ruby_llm.rb`
- `sig/ai_stream.rbs`
- `README.md`
- `README.ja.md`
- `CHANGELOG.md`
- `docs/agent-demo/lib-requests/LIB-001.md`
- `docs/agent-demo/lib-requests/LIB-002.md`
- `docs/agent-demo/lib-report.md`

## 自己検証

2026-09-05 JST、共有worktree（commit前、他担当の変更を含む）で実行した。

| コマンド | 結果 |
| --- | --- |
| `bundle exec rake test` | success: 27 runs, 91 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rbs validate` | success: exit 0 |
| `bundle exec rubocop` | success: 19 files, no offenses |
| `git diff --check` | success: 出力なし |

OpenAI回帰testは、app-owned `start-step` 内で `:content` adapterを流し、同じtool call IDの `tool-output-available` を追加してstepを閉じ、次provider callのtextを別stepへ連結してから終端する。この全event列を本物の `UIMessage::V1::Stream` へ通している。

RubyLLM回帰testは、異なる2toolが別provider completionでstream key `0` を再利用する列を作り、3 step、各tool output、usage合算、最終終端を本物のStreamで検証する。既存fixtureのtool result後にも新stepが始まる期待へ更新した。

## 互換性影響

- adapter initializerの新keywordは省略可能で、既定event列はOpenAIで不変。RubyLLMはtool-result後にprovider chunkが続く場合だけ、従来1 stepだった出力へ正しい `finish-step` / `start-step` が追加される。
- OpenAI `:content` はcallerが事前にmessageとstepを開始し、成功時はtool output後にstepを閉じ、最終messageを終端するための明示的な構成用APIである。provider failureはadapterが開いているpart/stepを閉じてterminal `error` を出す。
- RubyLLM usageは最後のcompletionだけからloop全体の合計へ変わる。各completion内では最後に観測したusage snapshotだけを採用し、stream chunkごとの累積値を重複加算しない。

## 未解決・待機事項

- app担当による両endpoint初回統合と、未対応lib依頼がないことの明示を待っている。
- 実API/model access/reasoning summaryの実観測はapp担当の検証範囲であり、このlibrary担当は課金リクエストを重複実行していない。

---

## 再開後の担当報告（2026-09-05、`/root/stream_library`）

状態: library自己検証とapp初回統合連絡完了。追加blocking lib依頼なしを受領し、報告後停止。
上記は停止前担当の記録として保持した。以下はresume-briefを優先して今回実施した内容。

### 承認の別HTTP継続

- [LIB-003](lib-requests/LIB-003.md) を作成・修正。既存Event schemaはinstalled AI SDKと一致していたが、
  完了したStreamは再利用できず、新Streamにはtool/approval宣言がないため後続outputが拒否される不足を再現した。
- `Stream.new(sink = nil, continuation: saved_events)` を追加。server保存のEvent列から同じ遷移検証で状態だけ復元し、
  過去のframeをemitしない。各HTTP区間のfinishを要求し、未完了・abort/error・不正順序を拒否する。
- 後続HTTPは同じassistant IDの `start` → `start_step` → `tool_approval_response` →
  `tool_output_available` または `tool_output_denied` → `finish_step` → `finish`。
  元のStreamへ書き続けるAPIではない。複数の完了HTTP区間も履歴として復元できる。
- 認可・承認IDと会話/本人/確定引数のbinding・永続化・陳腐化判定・exactly-once業務writeはapp責務のまま。
  `continuation:` はclientからの未検証履歴を信用する機能ではなく、tool実行もしない。
- RBS、英日README、CHANGELOG、限定回帰を追加。

### installed SDKで確認した契約

AI SDKはexample lockfileとinstalled `ai` **7.0.92** / `@ai-sdk/react` **4.0.95** を使用。
`node_modules/ai/src/ui/chat.ts` の `addToolApprovalResponse` はtoolを `approval-responded` に変え、
`sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithApprovalResponses` がtrueなら別HTTPを送る。
`process-ui-message-stream.ts` は同tool call/approval IDのresponse/outputを既存partへ反映する。

`test/integration/approval_continuation.mjs` はuseChatが利用する本物の `Chat` と `DefaultChatTransport` へ
`approval_frames.rb` が生成した実Ruby SSEを渡す。fake fetchのみ使用しnetwork/API呼出しはゼロ。
承認・拒否とも2 HTTP requests、同assistant 1件、同tool 1件を保持し、最終stateがそれぞれ
`output-available` / `output-denied` になることを確認した。React DOM/実ブラウザの操作証跡とは区別する。

### APP-001 / RubyLLM

[APP-001](lib-requests/APP-001.md) の旧1.16 API failureはSDKがChat Completionsを利用する制約で、
provider-neutral Event/Streamの不具合ではない。APP票とexample依存・runnerはapp所有のため直接変更していない。
app bundleには既にofficial repoの **9b30f939fe96b461e62ac62314350cf5c54f1394**（2.0開発版）がinstalled。
root bundleは **1.16.0** のまま維持した。

SDKローカルsourceと `test/integration/ruby_llm_responses.rb` の非課金再現で以下を確認した。

- `protocol: :responses` のendpointは `responses`。toolsとreasoning `{ effort: "medium", summary: "auto" }`
  を同じpayloadへ生成できる。`store: false` / `include: ["reasoning.encrypted_content"]` で、
  Messageのthinking.signatureを後続requestへ再投入する設計。
- Responses自身のparserでreasoning-summary、function call開始/引数、completed/usageをChunkへ変換し、
  現lib adapter→Streamへ通して正常終了。これは実APIでのモデル利用可否やreasoning出力の保証ではない。
- `Tool.requires_approval` / `Chat.awaiting_approval?` / `pending_approvals` / `approve` / `deny` が存在する。
  pending時の `run_tools` は実行0、approve後は実行1、同じapprove/run_tools再送でも実行1を非課金で確認。
  このSDK内の性質を業務DBの永続的なexactly-once保証とはみなさず、app側の検証へ委ねる。
- `Chat#complete` はawaiting_approvalで正常return。resolverがあるとChatのdecisionより優先し、
  resolverはidempotent readである必要がある。forced tool choiceはSDKがtool実行後に解除する。
- Responsesのcompletedはtool付きでもSDKが `finish_reason: :stop` へ変換する。
  approval待機判定は `pending_approvals` / `awaiting_approval?` で行うようappへ通知した。
- 停止前の追加差分に含まれていたRubyLLMのmodel/model_id、finish_reason、JSON tool-result対応を引継いだ。
  root1.16ではChunkにfinish_reason readerがないため、追加済みtestの `length` 固定期待が1件失敗した。
  1.16はfallback `stop`、開発版は公開readerに従う期待に修正し、両bundleで成功した。

### 今回の軽量自己検証

| 対象・コマンド | 結果 |
| --- | --- |
| root `bundle exec ruby -Itest test/ai_stream/ui_message/v1/test_stream.rb` | 12 runs / 49 assertions、0 failures/errors |
| root `node test/integration/approval_continuation.mjs` | approval + denialとも成功、network/APIゼロ |
| root `bundle exec ruby -Itest test/ai_stream/adapters/test_ruby_llm.rb` | 4 runs / 14 assertions、0 failures/errors（1.16） |
| example bundle `bundle exec ruby -I../../test ../../test/ai_stream/adapters/test_ruby_llm.rb` | 4 runs / 14 assertions、0 failures/errors（9b30） |
| example bundle `bundle exec ruby ../../test/integration/ruby_llm_responses.rb` | 2 runs / 17 assertions、0 failures/errors、network/APIゼロ |
| root `bundle exec rbs validate` | exit 0 |
| 変更対象6 Ruby filesのみ `bundle exec rubocop ...` | 6 files、no offenses |
| `git diff --check -- lib test sig README.md README.ja.md CHANGELOG.md` | exit 0 |

全suite・実APIの再実行はしていない。lintは変更箇所の指摘を修正するためのみ再実行。
`.env` / `.env.swp` / API keyは出力・変更していない。SDK契約fixtureは隔離されたRuby processでdummy keyを使い、
Rails initializerを読み込まず、通信も行わない。

### 連携・残件

- `/root/saas_app` へAPP-001のinstalled SDK契約と新continuation API、標準useChat再開の検証結果を直接通知済み。
- `/root/saas_article` へLIB-003とSDK/library責務の区別、fake HTTP証跡を直接通知済み。
- 実API両経路・モデルmedium/reasoning実観測・業務DB承認/reset/cache・実ブラウザ/GIFはapp担当へ集約。
- app初回統合の確認と、未解決blocking lib依頼の有無を待ち、受領後にここへ追記して停止する。

### 初回統合の受領・停止

2026-09-05、`/root/saas_app` から次の報告を直接受領した（lib担当による再検証はしていない）。

> 初回統合: Stream continuation保存Event列→approval response→outputをRails controllerで成功、
> 承認+1/重複+0/拒否/別session/引数改変/reset staleを非課金4tests29assertions成功。
> staleはapproved:false+tool_output_deniedで返します。RubyLLM requires_approvalとpending_approvalsを
> runner統合済みでこれから少数実API検証。現時点lib追加不足なし。

LIB-003の初回統合待ちは解消。未解決blocking lib依頼はなく、ライブラリ担当は報告後停止する。
APP-001の実API達成判定と両経路live/GIFの証跡は引き続きapp-reportを参照する。
本報告のSDK/HTTP fixture成功から実API成功を推定していない。
