# 再dispatch用の依頼文

2026-09-05、新しいタスクで以下の3担当を起動済み。全担当 `gpt-6-astra`, `reasoning_effort: high`, `fork_turns: none`。同じ `/Users/shuent/Develop/ruby-ai-stream` の未commit変更を引き継ぐ。親は分解者のみで監督しない。担当の自己検証は軽量に限定し報告後停止。各担当へ `resume-brief.md` を通知済み。以下はdispatchした依頼の記録。

## saas_app

既存のRails+Reactアプリを続きから実装する。所有は `examples/rails_demo/**`, `examples/react_client/**`, 必要なルート `.gitignore`, `docs/agent-demo/app-report.md`, `evidence/**`, `lib-requests/APP-*.md`, `images/rails-real-agent/**`。他担当の変更を戻さず、libや記事を直接書き換えない。追加subagent禁止。

resume-briefの全アプリ要件: SaaS dashboard/read/reset、承認付きwrite toolとDB反映、useChat標準承認UX、server会話継続、deterministic `/chat/no-llm-call`、ボタンのみ送信、両実API経路、SQLite cache、軽量自己検証、実ブラウザGIF。モデルはアプリ側 `gpt-5.6-luna / medium`、`.env` の `OPENAI_APIKEY` の使用は許可済みだが秘密出力/変更禁止。APP-001のRubyLLM阻害を現行SDK/lockfileから再開してlib担当と解決する。承認待機時の書込み禁止、正確な引数とのbinding、一度だけの実行、拒否/重複/他セッション/データreset後の扱いを実装する。少数の実APIターンでread→文脈依存の追質問→write承認をまとめて確認する。lib問題はMD票で別担当へ依頼、ブロッカーなら待つ。仕様と証跡は記事担当へ直接連絡。app-reportへ結果/未達/証拠/URLを記録し報告後停止。

## stream_library

所有は `lib/**`, ルート `test/**`, `sig/**`, 必要なルートGemfile/lockfile・README・CHANGELOG、`docs/agent-demo/lib-report.md`, `lib-requests/LIB-*.md`。共有変更を戻さずexamples/記事/親文書は編集しない。追加subagent禁止。

旧lib-reportとLIB-001/002修正を引き継ぐ。現存APP-001（RubyLLM Responses/tools/medium）についてinstalled SDK契約を確認しapp担当へ早めに連絡する。さらに既存 Event/Streamのtool_approval_request/responseが、installed AI SDK/useChat標準approvalのstream終了→HTTP承認応答→同じ会話/tool再開に対応するかを調査し、小さい再現を作る。実在するlib不足だけをMarkdown票に残して最小修正し、回帰テストを追加。provider-neutral責務を守り、業務承認永続化・DB操作はapp側に置く。SDK制約とlib不具合を混同しない。APP票は直接書き換えずlib-reportで対応を参照可。

必要なpublic API/approval continuation契約をapp担当へ直接知らせる。検証は変更対象の限定回帰と必要なRBS/lintのみ、既存全suiteやAPIを何度も回さない。原則実APIはapp担当へ集約し重複課金しない。初回統合・未解決blocking依頼が処理されるまで待受け、報告後停止。

## saas_article

所有は `articles/rails-real-ai-agent.md`, `docs/agent-demo/article-report.md`, `article-sources.md`。他担当のapp/lib/evidence/GIFは編集しない。追加subagent禁止。

前回記事と一次資料の読了記録・現在の草稿を活かし、resume-briefに沿って日本語のSaaS実践記事へ更新する。冒頭はRailsで本格的なAI agentを作る動機。通常の在庫管理dashboardとAIからのread/writeが同じ業務操作を使うこと、標準useChat approvalとbackend永続承認の分担、会話継続、deterministic demo、SQLite cache/reset、両SDKの違いを実装に即して説明する。app/lib担当と直接連絡し、実コードの必要部分だけ抜粋する。

実行結果とGIFはapp担当が軽量検証で取得したものを受領して掲載。独立したAPI実行やアプリの追加検証/監督はしない。未取得やcache再生を実live成功と記さない。証跡待ちの間は独立した執筆を進め、以後待つ。コード/結果/GIFと元証跡の対応・未達をarticle-reportに記録、published:false、公開しない。報告後停止。
