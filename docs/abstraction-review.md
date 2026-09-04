# RubyLLM::Stream::AISDK 独立レビュー

実装担当とは別のサブエージェントが、2026-09-04 に公開 API、抽象化境界、Rails での使い勝手、拡張性をコードと実行結果から評価した記録である。指摘を隠さず、修正前の判断と対応を分けて残す。

## 初回評価

| 観点 | 評点 | 要約 |
| --- | ---: | --- |
| 公開 API | 8/10 | `stream << chunk`、`write_message`、typed event、terminal API は発見しやすい |
| 抽象化の粒度 | 7/10 | wire adapter という境界は適切。一方、一つの class が変換・状態機械・JSON 検証・SSE 出力を担う |
| Rails での使い勝手 | 6/10 | `response.stream` へ直接書けるが、tool lifecycle と例外終端を正しく組み立てる必要がある |
| 拡張性 | 6/10 | event family は広い。protocol version、sink、agent lifecycle bridge の内部差し替え境界はまだ薄い |

良い点として、次が確認された。

- IO 直書きと buffered Rack body を同じ API で扱える
- RubyLLM が実際に持つ content、thinking、tool call だけを自動変換し、存在しない情報を推測しない
- reasoning、source、file、data、approval、tool failure まで typed API が覆う
- event order と JSON compatibility を server 側で早期検証する
- `tachyurgy/ai_stream` を参考にしつつ、runtime dependency を持たない

## 初回レビューで見つかった P1 と対応

| 指摘 | 再現・影響 | 対応 |
| --- | --- | --- |
| tool result が streamed input の確定前に届く | RubyLLM 1.16 の実 agent callback 順で `ProtocolError: tool invocation ... has no available input` | `write_message` が同じ step の未確定 input を一度だけ flush。valid、parallel、invalid JSON の回帰テストを追加 |
| default `bundle exec rake` が generated Rails files の lint で失敗 | GitHub Actions も赤になる | root RuboCop の責務を gem 本体へ限定し、example は各 project の検証へ分離。`NewCops` 方針も固定 |
| README の request shape が `useChat` と不一致 | client は `messages`、controller は `prompt` を要求して 400 | 最後の user message の text part を読む完全な対応例へ変更 |
| provider 例外で protocol terminal がない | browser は EOF しか観測できない | disconnect と一般例外を分け、後者は generic `error` + `[DONE]` を試みる Rails 例とテストを追加 |
| support matrix が過大 | RubyLLM 1.10–1.x を Ruby 4.0.1 一つでしか検証していない | dependency を RubyLLM 1.16 系へ狭め、CI を Ruby 3.2 / 3.3 / 3.4 / 4.0 に設定 |

## P2 の扱い

次の互換性問題も回帰テスト付きで対応した。

- RBS の sink を `IO` nominal type から、Rails の `ActionController::Live::Buffer` も満たす `write(String)` writer interface へ変更
- block 付き `Enumerable#each` が RBS どおり `self` を返すよう修正
- `RubyLLM::Content#text` と URL attachment を明示的に変換し、推測不能な local/IO attachment は部分出力前に `ProtocolError` とする
- 同じ non-nil tool id/name が各 fragment で再掲される provider を安全な continuation として扱い、name 変更や stream key 衝突は拒否

deterministic Rails fixture は protocol conformance 用であり、実 AI API は呼ばない。RubyLLM `Chat#ask` 全体の fake-provider integration と class の内部三分割は、公開 API の blocker ではなく次版の設計課題として残した。

## 境界についての最終見解

このライブラリは chat framework ではなく、RubyLLM / agent event から一つの browser wire contract への adapter として保つのがよい。model 選択、会話永続化、tool 実行、approval 認可、retry policy まで抱えると Rails application と責務が重なる。

将来分割するなら、公開 API を増やす前に内部を次の三つへ分ける余地がある。

1. RubyLLM event normalizer
2. UI Message protocol state machine
3. SSE sink / Rack body

初回の「公開 gem は P1 解消まで保留」という判定は妥当だった。P1 は実装と回帰テストで解消し、残る課題は API 境界を壊さず内部を育てるための P2 として管理する。

## 修正後の再レビュー

別エージェントが同じ観点で再確認し、前回の P1 と上記 core P2 がコード・テスト上解消したことを確認した。その過程で、`~> 1.16` は 1.16.x 限定ではなく `< 2.0` まで許すという README との最後の不一致も発見した。gemspec を `~> 1.16.0` へ修正し、gem を再 build した。

最終ローカル結果:

```text
core:    24 runs, 100 assertions, 0 failures, 0 errors
RuboCop: 9 files inspected, no offenses detected
RBS:     validate success
Rails:   6 runs, 53 assertions, 0 failures, 0 errors
React:   3 tests passed
Vite:    production build succeeded
gem:     README/RBSを含有、runtime dependency ruby_llm ~> 1.16.0
```

最終判定は **ローカル公開 blocker なし / 0.1.0 GO**。RubyGems 公開操作そのものは行っていない。公開前には GitHub 上で Ruby 3.2 / 3.3 / 3.4 / 4.0 matrix が実走成功することを release gate とする。
