# 実AI agent sample / Zenn記事 — 監督への引継ぎ

> 再開後の現行指示は [resume-brief.md](resume-brief.md)。subagentは **gpt-6-astra / high** へ変更。SaaS dashboard・reset・承認付きwrite・会話継続・`/chat/no-llm-call`・ボタンのみの送信を追加し、検証は軽量に限定する。以下は停止前の分担履歴で、競合時は再開指示が優先。

## 役割境界

ユーザー指定: この親モデルはタスク分解者であり監督しない。作業を **gpt-5.6-sol / high** に dispatch し、品質チェックリストと検証方法を整備する。各担当が報告した後、この親モデルは追検証・追加修正指示を出さず待機する。監督はこのコンテキストを引き継ぐ別モデルが行う。

担当自身の実装中のテスト・実API検証・証跡作成は dispatch に含めた。担当による完了報告は監督の検証合格を意味しない。親による実装・試験・動作確認は実施していない。

## Dispatch 済み

| Agent | モデル / effort | 所有・責務 | 報告先 |
| --- | --- | --- | --- |
| `/root/sample_app` | `gpt-5.6-sol` / `high` | `examples/rails_demo/**`, `examples/react_client/**`, 必要なルート `.gitignore`、実API証跡、実ブラウザGIF、APP依頼票 | `app-report.md` |
| `/root/lib_fixes` | `gpt-5.6-sol` / `high` | `lib/**`, ルート `test/**`, `sig/**`, 必要なルート依存・lib説明・CHANGELOG、LIB依頼票 | `lib-report.md` |
| `/root/zenn_article` | `gpt-5.6-sol` / `high` | `articles/rails-real-ai-agent.md`, `article-sources.md`, 記事報告 | `article-report.md` |

親所有: この文書、`quality-checklist.md`、`verification-plan.md`。各担当に共有作業・他担当の変更を戻さないこと・追加subagentを起動しないことを指定済み。

## 決定した実装方針

- 既存 Rails API と React / AI SDK `useChat` を拡張する。同じUIからOpenAI公式SDKアダプターとRubyLLMアダプターの別エンドポイントを使う。正確なルート・ファイル構成はアプリ担当が報告する。
- ユースケースはEC在庫補充。seedしたデモ在庫・販売実績・仕入条件を複数ツールで参照し、補充案を作る。実業務の購買注文は送らない。LLMは実API、業務データはデモであることを明示する。
- 1ユーザー依頼内で2種類以上のツールをLLMが呼ぶ。ツール結果をモデルへ返し、最終回答に根拠を反映する。結果をchat内のカードで表示する。
- 日本語のChatGPT風UI、sidebar / messages / composer。テンプレートボタンは編集可能な本文を入力欄に挿入する（placeholderだけ更新して空文字を送る仕様にはしない）。送信は別操作。raw stateは閉じたHTML `details`。
- SQLiteで結果を永続cache。adapter・model・reasoning・会話context・system/tool/seed versionを区別。同じ条件のcache hitはAPI呼出し不要。再生成は明示的にbypassし、成功結果のみ保存する。
- APIモデルは **`gpt-5.6-luna` / reasoning `medium`**。指定を黙って変更しない。reasoning summaryイベントの実観測を目指し、出ない場合は未達・制約として記録する。
- 実API利用と課金を伴う検証はユーザー許可済み。ルート `.env` の **`OPENAI_APIKEY`** をサーバーから読み込む。キーや `.env` / `.env.swp` 内容は出力しない・上書きしない。開始時この2ファイルは未追跡だった。
- 記事は冒頭のモチベーションを「Railsで本格的なAI agentを作ってみる」とし、前回のlib紹介に続く実践編にする。必要なコードのみ抜粋し、取得済み実行結果と実ブラウザGIFを掲載する。`published: false`。公開作業は依頼されていない。

## 依存関係と待機

1. lib担当はmulti-step / tool lifecycleの実在する不足を先行調査し、アプリ担当へ契約を連絡する。
2. アプリ担当はlib不具合を `lib-requests/APP-NNN.md` に記録しlib担当へ直接依頼する。lib担当発見分は `LIB-NNN.md`。ブロックされる経路は修正を待ち、別実装で隠さない。
3. lib担当は初回統合と依頼票処理を待ち、必要な回帰試験後に報告する。
4. アプリ担当は実装と自己検証を行い、`evidence/` と `/images/rails-real-agent/` に証跡を作って記事担当へ通知する。
5. 記事担当は並行して資料・構成・本文を準備し、提供された実コードと証跡を記事へ反映する。アプリの追加監督・検証はしない。
6. 各担当は最終報告後に作業を停止する。別モデルの監督が引き継ぐまで、この親は再実行・レビュー・検証・修正dispatchをしない。

## 引継ぎ時の読み順

1. この文書とユーザーの元の指示。
2. `app-report.md`, `lib-report.md`, `article-report.md`（未存在なら未報告）。
3. `lib-requests/` の未解決票。
4. [品質チェックリスト](quality-checklist.md) と [検証方法](verification-plan.md)。
5. 担当が報告した証跡・実行コマンド・起動URL。成果物や合格は、引き継いだ監督が確認するまで担当の自己申告として扱う。

## 参考資料・初期調査

- 前回記事: https://zenn.dev/shuent/articles/e0c159cd2989f9 （親のweb取得は失敗、本文取得は記事担当へ依頼済み）
- Generative UI: https://ai-sdk.dev/docs/ai-sdk-ui/generative-user-interfaces （親のweb取得はMarkdown content-typeで失敗、担当へ別の取得方法で確認を依頼）
- モデル公式資料: https://developers.openai.com/api/docs/models/gpt-5.6-luna （親が取得済み、medium対応。アカウントでの実利用成功は未検証）
- reasoning: https://developers.openai.com/api/docs/guides/reasoning （親が取得済み、SDKの具体的指定・実観測は担当責務）
- 適用方針: `rails_policy`, `development_order`, OpenAI Docs。React/useChatを使う今回の目的を優先し、Rails例を全面Hotwire移行する作業は依頼していない。
