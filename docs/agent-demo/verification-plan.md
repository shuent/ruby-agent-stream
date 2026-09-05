# 検証方法（担当の自己検証と次の監督用）

> 現在は [resume-brief.md](resume-brief.md) の軽量検証に限定する。以下のフルマトリクスは停止前の計画であり、全項目の再実行は不要。少数の実APIターンで複数tool・会話継続・write承認をまとめて確認し、拒否/重複等は小さい非課金テストで確認する。

この文書は計画であり実行結果ではない。タスク分解者の親モデルは実行しない。担当は必要な自己検証を実施し報告後停止する。次のモデルは報告と証跡を読んでから、未確認点・失敗・変更に応じた検証を行う。

## 1. 実行前の把握

1. `app-report.md` / `lib-report.md` / `article-report.md` と未解決依頼票を読む。
2. 作業treeの対象変更、SDKとRuby/Node version、SQLite DB path、API routes、起動URLを把握する。秘密の内容を表示しない。
3. アプリREADMEに従い依存を用意し、対象DBだけmigration/seedする。ユーザーの既存DBを破棄しない。
4. serverだけがルート.envの `OPENAI_APIKEY` を読むことを確認する。client側へキーを渡さない。

## 2. 自動チェック

既存の標準コマンドは以下。依存追加後の正確なコマンドは担当報告を優先する。fixtureテストの成功を実API成功とは区別する。

| 作業ディレクトリ | コマンド | 目的 |
| --- | --- | --- |
| repository root | `bundle exec rake test` | core/adapters回帰 |
| repository root | `bundle exec rbs validate` | 公開型契約 |
| repository root | `bundle exec rubocop` | Ruby lint |
| `examples/rails_demo` | `bin/rails test` | controllers/models/cache/tool/失敗処理 |
| `examples/react_client` | `npm test` | parts/composer/cache操作等のUI回帰 |
| `examples/react_client` | `npm run build` | TypeScriptとproduction build |

ERBを変更した場合は導入済み/担当が報告するHerbチェックを行う。副作用の少ないスタイル変更だけのために実装を写したテストを増やさない。loop上限、複数step、cache衝突、停止中断など失敗すると意味のある契約を重点にする。

## 3. 実APIマトリクス

同じseedとテンプレート、同じ新規会話contextでOpenAI・RubyLLMを別々に検証する。各経路で少なくとも以下のrunを記録する。回数無制限のリトライはせず、API失敗は内容を記録する。

| Run | 操作 | 期待・証明 |
| --- | --- | --- |
| LIVE | 新規会話、テンプレート挿入、cache missで送信 | 指定model/medium、2種類以上のLLM tool call、各結果、reasoning summary、最終回答 |
| HIT | 同一の会話入力contextから同一promptを再送 | SQLite cache hit、同じ結果、provider request件数差分0 |
| RESTART | Railsのみ停止/同じDBで再起動し、同一条件を再送 | 永続cache hit、provider request件数差分0 |
| REGENERATE | cacheがある条件で再生成 | 新しいprovider request、live完了、新しい生成識別子/cache保存日時 |

HITテストで会話に前のassistant結果を追加するとcontextが異なるため、同一条件のテストにならない。新規会話から同じ初期contextを再現するか、担当が提供する再現scriptを用いる。文章の差異だけで再生成を証明しない（新規生成でも同じ出力になることがある）。API呼出しログはauthorization/headerを記録せず、request counter、request/run IDなどで判定する。

モデルaccessが拒否された場合はモデル置換をせず、statusとsecretを含まないerrorを記録して未達にする。medium設定だけでは可視reasoningが必ず出た証拠にはならない。実SSEのreasoning-start/delta/endまたは実adapter eventを記録し、token countと区別する。

## 4. ブラウザでの操作

1. 起動URLを開き、テンプレートボタン→入力欄の本文→編集→送信を操作する。data-testidを利用する。
2. 両adapterで実LIVE runを操作し、2種類以上のtoolが途中状態からcardsになり、最終回答が出ることを確認する。
3. raw stateのdetailsを開閉し、UI表示とtool call ID/結果が対応することを確認する。
4. 新規会話と追質問でcontextを確認し、adapter切替で会話/結果が混線しないことを確認する。
5. cache hitと再生成の表示・操作を確認する。停止は十分長い実streamで行い、以後UIが固まらず、未完了結果を成功cacheにしないことを確認する。
6. API/tool errorのUIを確認する。再現が不確実なrate limitを大量API呼出しで誘発せず、明示したテスト用の失敗経路も補助に使う。実APIエラーと注入失敗を区別して記録する。
7. 幅の狭いviewportで入力欄、sidebar、カードのoverflow、フォーカス/キーボード操作を確認する。

## 5. GIFと証跡

- app担当の実ブラウザセッションを収録する。生成画像から動作GIFを作らない。実API完了を確認してから「検証済み」の説明に使う。
- 最低1経路はLIVEのテンプレート選択→送信→複数tool cards→最終回答を含める。両経路の静的証跡/SSEも保持する。
- `images/rails-real-agent/` に記事用GIF、`docs/agent-demo/evidence/` にsecret除去した結果とmanifestを置く。
- manifest項目: 実行日時/TZ、adapter、endpoint、model、effort、promptとcontext、seed/tool version、run ID、cache状態、provider呼出し件数、tool名/call ID/結果、reasoning種別、完了状態、GIF path、録画の速度変更/切取りがあればその旨。
- チャット中の必要な要約と取得結果のみを保存し、認証情報・.env内容・不要なprivate情報は含めない。
- GIFを実際に再生し、先頭/途中/末尾の表示と文章の可読性、記事リンク先、ファイル容量を確認する。映像を確認できない場合に「確認済み」にしない。

## 6. lib依頼票

`lib-requests/APP-NNN.md` または `LIB-NNN.md` に以下を記す。

```markdown
# APP-001: 具体的な症状
状態: open / implementing / fixed / blocked
担当: /root/lib_fixes
アプリをブロックするか: yes/no（経路も記載）
SDK/model/呼び出し条件:
最小再現・コマンド:
期待:
実際:
secret除去した証拠:
必要な契約/修正案:
修正ファイル・互換性:
回帰テスト・結果:
アプリ担当への通知:
```

依頼票の報告者と修正担当の所有を尊重し、app票をlib担当が無断で書き換えず、対応状況はlib-reportから参照してもよい。appがブロックされる修正を待たずに成功扱いしない。

## 7. 記事の確認

1. 動機から始まり、前回記事を実際に踏まえているか読む。
2. 掲載コードと実装の対応表を確認し、抜粋の範囲と再現手順が一致するか確認する。
3. 実行結果とGIFをmanifestのrunへ照合し、live/cache/mockの区別を確認する。
4. 両adapterの違い、業務デモseed、reasoning制約、cache再生成の挙動について実証範囲を超える主張がないか確認する。
5. Zennの画像pathとfrontmatterを確認し、published:falseを維持する。投稿・公開は行わない。

## 8. 停止条件

担当は成果物・自己検証結果・残課題を報告したら停止する。タスク分解者は報告を受けても検証を開始しない。監督を引き継ぐ別モデルだけが未達項目を評価し、必要な追加検証/修正を判断する。
