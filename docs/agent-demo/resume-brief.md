# 再開指示 — 現在の要件と軽量検証

この文書は旧handoff/checklist/verification-planの競合する指示に優先する。元の実API・両adapter・SQLite cache・GIF・記事要件は維持し、以下を追加・変更する。

## 起動状態: 新しいタスクで3担当の再dispatch成立（2026-09-05）

旧タスクでは `agent thread limit reached` / `agent path already exists` / `not_found` により再dispatchできなかった。ユーザー承認済みの新しいタスクで、同じ保存プロジェクトの未commit変更を引き継ぎ、以下の3担当のspawnが成功した。全担当 **gpt-6-astra / high / fork_turns: none**。

- `/root/saas_app`: アプリ・自己検証・証跡/GIF。
- `/root/stream_library`: lib・限定回帰・アプリとの統合連携。
- `/root/saas_article`: 記事・提供された証跡の反映。

各担当へこの文書とredispatchの依頼・所有区分、直接連携、既存変更の保持、追加subagent禁止、軽量自己検証後の停止を通知済み。親は起動と引継ぎ文書整備のみを行い、実装・追検証・追加修正指示は行わない。完了報告後はユーザー/次モデル監督へ引き継いで待機する。

## 役割・モデル

- 停止前の変更をそのまま引き継ぎ、作り直さない。旧3担当はusage limitで停止。現在の作業treeは未commitで、他担当の変更を戻さない。
- ユーザーがモデル名を確認済み: 新しいsubagentは **gpt-6-astra / high**。アプリが呼ぶモデルは従来の **gpt-5.6-luna / medium** のまま。
- 親はタスク分解・dispatch・引継ぎ文書整備だけを担当。監督しない。各担当は自己検証を軽量に限定し、報告後停止する。親は追検証せず次モデルの監督を待つ。
- 起動済みの新担当: `/root/saas_app`（アプリ全体）、`/root/stream_library`（lib）、`/root/saas_article`（記事）。担当同士で直接連携する。

## 再開地点

- アプリ: Railsのagentモデル、OpenAI/RubyLLM runner、SQLite cache/run/seed、React chatは途中まで存在。app-reportは未存在。
- lib: OpenAI lifecycle compositionとRubyLLM step/key再利用対応は旧lib-reportに自己検証済みとして記載。今回親は検証していない。
- `lib-requests/APP-001.md`: RubyLLM 1.16のtools + reasoning併用に関する実API阻害が記録されている。runnerはResponses指定へ変更途中。現在の依存・SDK契約を調べて解決する。
- 記事: 前記事・一次資料を読んだ草稿あり。実行結果とGIFは未掲載。証跡があると仮定しない。

## SaaSとしての公開操作と契約

実装前に `examples/react_client/src/domain.ts` へUI側の公開入力/出力/操作契約を整理する。Rails側は既存モデルを活かし、業務処理をcontrollerやtoolへ重複させない。認証・課金等のSaaS製品機能追加は今回の必須範囲ではない。

| 操作 | 振る舞い |
| --- | --- |
| ダッシュボード参照 | 在庫・販売・仕入条件とAIが作成した補充発注レコードを同じSQLite業務データから表示する。デモデータと明示 |
| デモデータreset | 画面から確認して既知のseed状態へ戻す。対象はexampleのデモ業務データだけ。古いcache/保留承認が新しい状態へ適用されない |
| 会話開始/続行 | 会話IDとserver側の履歴を紐づけ、続きの依頼に先行メッセージ・関連tool結果が反映される。新規会話/別セッションから分離 |
| read tools | 既存の在庫・販売・仕入条件・補充計算をSaaS操作としてLLMへ公開 |
| write tool | 例: `create_replenishment_order`。SKU・数量等を検証し、SQLiteへ補充発注を登録する。外部仕入先へ発注は送らない |
| 承認/拒否 | write提案に対する人間の判断を保存し、承認した正確な操作・引数だけを一度実行する。拒否時は業務DB変更なし |

write toolは単に「提案を表示」して終了せず、承認後に実際の業務DB writeとダッシュボード反映まで実装する。会話・実行ログ・保留承認の保存は、承認対象の業務writeとは区別する。

## 承認フロー

- AI SDK/useChatの標準tool approval stateと `addToolApprovalResponse` 等の対応する公開APIを優先する。approvalカードの最小の承認/拒否ボタンは必要。バックエンドの永続状態とtool実行制御を主体にし、別の独自チャット状態機械を作らない。
- APIの実在・送信/再開方法はinstalled SDK/一次資料で確認する。バックエンドだけで既存UIが自動的に承認UXを描画すると仮定しない。
- approval request→stream終了/待機→別HTTP requestで応答→同じassistant/tool callを継続、の標準操作を確認する。
- 承認前に業務DBを変更しない。拒否、リロード、重複応答で副作用を起こさない。承認IDはserver側で会話・tool call・確定引数に紐づける。clientが書き換えた引数を実行しない。
- resetや元データ変更で陳腐化した承認は拒否/再提案し、cache replayでwriteを再実行しない。
- libの承認eventは既存 `Event`/`Stream` にある。実useChat契約で不足があれば再現を依頼票に書いて別lib担当が最小修正する。SDK制約とlib制約を分けて記録する。

## UI・経路

- `POST /chat/no-llm-call` は前のdeterministic `DemoModel` を用い、API keyなしで利用可能。UIからも選択・起動できるようにする。既存 `/chat` は互換aliasとして維持可。
- live経路は引き続き `/chat/openai` と `/chat/ruby_llm`。dashboardを基本画面、AI agentをSaaSを自然言語で使う機能として配置する。
- Enter送信は廃止し、送信ボタンだけで送る。通常Enter/Shift+Enter/日本語IME確定は送信せず入力を維持する。承認後の標準自動継続は本文のEnter送信とは別。
- promptテンプレート、cache/再生成、detailsのraw stateは維持。承認待ちと実行完了/拒否が区別できるUI。

## 軽量検証の必須チェック

広い総当たり・何度もの全suite・大きな生ログ・API大量再試行はしない。変更箇所の小さなテストと、少数のまとめたブラウザ/APIシナリオで確認する。既存の有効な証跡は再利用する。ログは件数・ID・状態・要約で報告。

- [ ] deterministic endpointを1回、API呼出しなしで確認。
- [ ] Reactの小さい確認: EnterとIME確定で送信0回、ボタンクリックで1回。
- [ ] dashboardのreadとresetを小さいmodel/controller確認にまとめ、対象デモデータだけが戻ることを確認。
- [ ] 両adapterで少数の実APIターンを行う。最初に複数read tool、次に「先ほどのSKUを○点で登録して」のような省略を含む続きの依頼を使い、会話継続とwrite承認まで兼用して確かめる。
- [ ] approval待機時の業務DB件数不変、承認後+1とUI反映を確認。拒否/同じ承認再送/別セッション応答/引数改変/reset後応答は小さい非課金の回帰テストでまとめる。
- [ ] cache hitでAPI不要、再生成で新規生成、データwrite/resetで古いcacheを使わない、cached writeを再実行しない。永続性の確認は既存証跡がなければ1回に限定。
- [ ] libは変更契約の限定回帰・必要なRBS/lintのみ。全suiteが短くても繰返し実施しない。
- [ ] 短い実ブラウザ操作でdashboard→chat→承認→DB結果の反映を確認・収録し、記事GIFにも兼用する。新たな長時間の録画/総当たりは不要。
- [ ] 実API指定モデル/medium/reasoningイベントの観測結果を要約。未達は記録し、証跡を捏造しない。

## 記事の更新

「Railsで在庫管理SaaSを作り、そのSaaSをAI nativeに使ってみる」という実践編へ更新。データの通常UIとAI操作が同じ業務処理を使うこと、read toolsと承認付きwrite、続きの会話、deterministic demo、cache/resetの関係を示す。承認のuseChatとbackendの分担、必要になったlib変更を実装に即して説明する。短い実録GIFと取得済み出力を掲載、未検証は未検証と記載し `published: false` を維持。

## 担当報告

旧報告を消さず、再開後の変更/軽量検証/証拠/未達を追記・更新する。新担当の所有は旧担当と同じ区分。app担当は `app-report.md`、lib担当は `lib-report.md`、記事担当は `article-report.md`。親は受領後に検証を進めない。
