# 記事作成レポート

現在: 再開後の記事担当作業を終了。未公開草稿に実コード・非課金実アプリGIF・取得済み結果を反映。両SDK実APIの証跡は未達。詳細は末尾の「再開後の最終報告」を参照。以下の停止前記録も保持している。

## 状態

草稿。実装確定情報、実API実行証跡、実ブラウザGIFの受領待ちであり、記事完成扱いではない。

## 記事

- パス: `articles/rails-real-ai-agent.md`
- 言語: 日本語
- frontmatter: `published: false`
- 現在の構成: 動機、前回記事との接続、ユースケース、構成、agent loop、multi-stepで判明したlib修正、Generative UI、model/reasoning、SQLite cache、実行方法、実行例、学び

## 参照資料

公開資料とリポジトリ内資料の一覧は `docs/agent-demo/article-sources.md` に記録した。前回のZenn記事はブラウザで本文を通読し、重複説明を短くした。

## コード引用元

実装確定後に記入する。現時点の記事には、アプリ実装を表す未確認のコード抜粋を掲載していない。

| 記事の節 | 引用元 | 状態 |
| --- | --- | --- |
| OpenAI公式SDK側 | 受領待ち | 未掲載 |
| RubyLLM側 | 受領待ち | 未掲載 |
| Generative UI | 受領待ち | 未掲載 |
| SQLite cache / regenerate | 受領待ち | 未掲載 |

## GIF・実行証跡対応表

| 記事内の表示 | provider | run ID | model / reasoning | 証跡 | GIF | 状態 |
| --- | --- | --- | --- | --- | --- | --- |
| OpenAI公式SDKの実行例 | OpenAI | 受領待ち | `gpt-5.6-luna` / `medium` | 受領待ち | 受領待ち | 未掲載 |
| RubyLLMの実行例 | RubyLLM | 受領待ち | `gpt-5.6-luna` / `medium` | 受領待ち | 受領待ち | 未掲載 |
| SQLite cache再生 | 受領待ち | 受領待ち | 受領待ち | 受領待ち | 受領待ち | 未掲載 |
| 再生成 | 受領待ち | 受領待ち | 受領待ち | 受領待ち | 受領待ち | 未掲載 |

## 未達チェック

- [ ] 実装済みendpoint、agent loop、tool名と記事の記述を照合
- [ ] OpenAI公式SDKとRubyLLMの最小コードを、存在する実コードから引用
- [ ] コード抜粋の省略位置を明示
- [ ] 一依頼中に二種類以上のtoolを実行した実API証跡を掲載
- [ ] tool結果をLLMへ戻して最終補充案を得た証跡を掲載
- [ ] run ID、provider、model、reasoning、tool、最終結果を記事と証跡で対応
- [ ] 実ブラウザで取得したGIFを`/images/rails-real-agent/...`で掲載
- [ ] cache replayをlive実行と区別
- [ ] regenerateがcacheを迂回した証跡を確認して記述
- [ ] 確認済みの再現コマンドを掲載
- [ ] `lib_fixes`の確定内容を反映
- [ ] `docs/agent-demo/quality-checklist.md`へ適合
- [ ] `docs/agent-demo/verification-plan.md`へ適合
- [x] seedデータと実業務データを区別
- [x] 前回記事を通読し、重複説明を抑えて続編として接続
- [x] OpenAIとAI SDKの一次資料を参照
- [x] 秘密値を記事・資料へ掲載していない
- [x] `published: false`

## 公開設定の自己申告

`articles/rails-real-ai-agent.md`のfrontmatterは`published: false`である。公開操作は行っていない。

## 再開後の作業（2026-09-05）

上記は停止前の報告として保持する。現在の要件は`resume-brief.md`が優先し、旧quality-checklist/verification-planへの全面適合を追加実行の条件にしない。

- 在庫SaaSのdashboard → 調査 → 文脈を使う追質問 → write承認 → DB結果という構成へ草稿を更新。
- 通常UIとAIの共通業務操作、read/write、useChatの標準approvalとbackendの役割、会話、deterministic、cache/resetを追加。
- `InventoryCatalog#calculate_replenishment`の実計算部分を引用。レコード取得と戻り値を省略したことを本文に明記。
- `addToolApprovalResponse`と標準自動続行helperのinstalled sourceをread-onlyで確認。AI SDKの公開ページ本文は取得エラーのため、読了とは扱わない。
- app/lib担当へ直接連絡済み。確定実装、自己検証の実行結果、実アプリGIFは未受領。本文の`APP_*` / `LIB_FINAL`コメントは受領後の差し込み箇所であり、完成扱いにしない。
- アプリ/APIの独立実行、追加ブラウザ検証、証跡/GIF編集は実施していない。
- 所有する記事・記事report・article-sourcesのみを編集。公開操作なし、`published: false`を維持。

### lib共有の受領

`/root/stream_library`から、別HTTP承認継続に必要な`Stream.new(sink, continuation: prior_events)`契約とAPIなし再現の成功報告を受領した。記事へ追記済み。対象はinstalled AI SDK 7.0.92 / React hook 4.0.95、標準approval API、承認/拒否とも2HTTP・assistant1・tool1。これはfake HTTPのprotocol確認であり、app実APIや業務DB検証とは扱わない。

APP-001のRubyLLM 1.16制約と開発版Responses対応も分離して記述。最終appの依存版とlive結果は未受領。

### lib確定文書の対応

再開後の詳細報告と`lib-requests/LIB-003.md`を受領・読了。本文の「multi-stepで必要になったlibの修正」はLIB-001/002/003に対応する。

| 記事の記述 | 元証跡 | 扱い |
| --- | --- | --- |
| approval continuation、同じassistant/toolで承認・拒否 | `lib-report.md`再開後報告、`lib-requests/LIB-003.md`、`test/integration/approval_continuation.mjs` | lib担当の自己検証。fake HTTP、実API/実ブラウザではない |
| RubyLLM開発版Responses/tools/medium契約 | `lib-report.md`のAPP-001節、`test/integration/ruby_llm_responses.rb` | 2 runs / 17 assertions。APIなしのSDK契約検証 |
| RubyLLM両版のadapter互換 | `lib-report.md`の軽量自己検証表 | root1.16とapp9b30それぞれ4 runs / 14 assertions |

記事担当は上記testを再実行していない。

## 再開後の最終報告（2026-09-05）

記事担当の編集と軽量自己照合を終了。`articles/rails-real-ai-agent.md`は**未公開草稿**として更新完了。実API要件は未達であり、プロジェクト全体や記事のlive実証が完了したとは扱わない。app/libの報告後に追加修正依頼・追検証はしていない。この報告後は停止する。

### 反映した確定実装

- 通常の在庫dashboard/read toolが`InventoryCatalog`と同じSQLiteを使う構成。
- `create_replenishment_order`の承認要求、server保存の正確なinput/会話/assistant/tool binding、データrevision、DB transactionとunique index。
- 標準`useChat` approvalと自動HTTP続行、`Stream`のserver Event continuationの分担。
- 承認直後はLLM再呼び出しをせず、Railsの業務writeと定型結果を返すことを明記。
- サーバー履歴とtool結果をJSON文字列として次ターンへ渡す方式、リロード復元、ローカルデモのsession分離。
- OpenAI公式SDKのResponses loopとRubyLLM2.0開発版のnative承認待機の違い。SDK1.16のAPP-001とlib不足のLIB-003を分離。
- `DemoModel`のAPI不要経路は旧固定protocolデモで、実モデルの在庫操作とは分離。
- 結果cache、再生成bypass、write/approval非cache、resetによるrevision更新とcache失効。
- Enter/Shift+Enter/IMEで本文を送らず、ボタンだけで送信するUI。

### 実コード抜粋対応（本文登場順）

Ruby/TSXコードは10ブロック。空白を正規化した各ブロックが、以下の実ファイルの連続部分に一致することを記事の転記確認として照合した。各抜粋で省略した周囲の範囲を本文に説明。擬似コードを実装として掲載していない。

| ブロック | 記事の説明 | 引用元 |
| --- | --- | --- |
| 1 | 補充数の計算 | `examples/rails_demo/app/models/inventory_catalog.rb` / `calculate_replenishment` |
| 2 | useChat設定 | `examples/react_client/src/App.tsx` / `ChatSession` |
| 3 | 承認ボタン | 同上 / `ToolCard` |
| 4 | 保存済み承認の判断とDB登録 | `examples/rails_demo/app/models/agent_approval.rb` / `decide!` |
| 5 | 次ターンのserver文脈 | `examples/rails_demo/app/models/agent_chat.rb` / `prior_messages` |
| 6 | Responses stream | `examples/rails_demo/app/models/openai_agent_runner.rb` / `each` |
| 7 | OpenAI write待機分岐 | 同上 |
| 8 | RubyLLM Responses/thinking設定 | `examples/rails_demo/app/models/ruby_llm_agent_runner.rb` / `each` |
| 9 | RubyLLM pending approval | 同上 |
| 10 | cache key | `examples/rails_demo/app/models/agent_cache_key.rb` / `digest` |

起動コマンドはapp担当の`examples/rails_demo/README.md`とapp-reportの確認済み起動手順に対応。記事担当自身は起動・テスト・APIを実行していない。

### 結果・GIFと元証跡の対応

元の取得結果は`docs/agent-demo/app-report.md`および`evidence/rails-real-agent/verification-summary.json`。記事担当はapp担当の軽量自己検証として受領し、独立検証していない。

| 本文掲載項目 | 元証跡の位置 | run / provider / modelの区分 |
| --- | --- | --- |
| API不要固定demo完了 | JSON `browser.deterministic_demo`、app-reportの実ブラウザ節 | `DemoModel`、APIなし、モデル生成run IDなし |
| pendingリロード→承認→DB0→1→dashboard | JSON `browser`、app-reportの非課金fixture節 | appの`script/non_billing_browser_fixture.rb`。提案はfixture、承認後は実local HTTP/SQLite。live runではない |
| 登録番号1 / TEA-GRN / 60点 / 45,600円 / 外部送信なし | JSON `browser.order` | 本文JSONブロックはこのオブジェクトを転記。LLM回答文ではない |
| 実画面GIF | JSON `gif`、app-reportのGIF対応説明 | `images/rails-real-agent/non-billing-approval.gif`。4実スクリーンショット各2.2秒。モデル生成でも連続動画録画でもない |
| GIFフレーム元 | `01-dashboard.png` → `03-fixture-approval.png` → `04-fixture-registered.png` → `05-fixture-dashboard.png` | 同ディレクトリ。`02-deterministic.png`はGIFに含まない |
| 承認回帰4 runs / 29 assertions | JSON `rails_focused_tests` / `saas_flow_test.rb` | APIなしの対象回帰 |
| context/cache 1 run / 10 assertions | 同上 / `agent_chat_test.rb` | provider fixture。実モデルの省略追質問を確認したとは記さない |
| プロセス間cache miss→hit | JSON `cache_persistence` | PID5003→5043、API0。PIDをrun IDと記さない。検証cache削除済み |
| React3 tests/build | JSON `react_tests`およびapp-report | APIなし。個別Rails testを最終全suite一括passとは記さない |
| 両SDKのlive結果 | JSON `live_api.status=not_executed`、`remaining`、app-report未達 | live run IDなし、成功回答未掲載。`gpt-5.6-luna/medium`は設定値、reasoning実観測なし |

GIF参照先の存在のみ記事のリンク確認として確認。565,006 bytes、SHA-256 `ac9d973cc7da6a137e51e9eb024ae70d9d632664b7965e5a2c511026feb9d4df`。GIF自体の編集、アプリ追加操作、追加視覚QAは実施していない。

### 未達

- 両adapterで複数read tool→tool結果を戻した最終回答→文脈依存の追質問→write提案という**実API**証跡は未取得。
- 指定モデル`gpt-5.6-luna` / `medium`の実応答とreasoningイベントは未観測。
- 実API由来のcache再生・再生成は未確認。非課金の仕組み確認だけを掲載した。
- live生成の実行結果とlive GIFを掲載する要件は未達。非課金fixtureの実アプリGIFを正確な注記付きで掲載した。

理由はapp担当の実API送信が自動承認審査に2回拒否されたため。外部seed送信・課金への直接user許可をtrusted contextで確認できず、repo内許可記録を代用できないという判定だった。別経路での回避、再試行指示、記事担当によるAPI実行はしていない。許可と次担当の実API検証が必要な残件として引き継ぐ。

### 記事担当の軽量自己照合

- 実Ruby/TSX抜粋10件を現行ソースの連続部分と照合。初回は承認ボタンを改行整形したため単純照合に不一致が出たので、実装と同じ1行へ戻して再照合し全件一致。
- `published: false`と差し込み用`APP_*`/`LIB_FINAL`コメントの解消、GIF参照ファイルの存在を確認。
- 本文JSONを元証跡の`browser.order`と照合。
- 所有3文書のみの`git diff --check`を実施。
- `.env` / `.env.swp` / key値を読まず、出力・変更・掲載していない。
- 公開・commit・pushを行っていない。共有app/lib/evidence/GIFの変更を戻していない。
