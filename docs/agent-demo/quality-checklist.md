# 品質チェックリスト

> 現在は [再開指示の軽量検証チェック](resume-brief.md) を優先する。以下は品質の参照基準であり、広範囲の再検証を要求しない。SaaS read/reset、会話継続、承認付きDB write、deterministic endpoint、ボタンのみの送信を追加済み。

すべて初期状態は未検証。担当報告には証跡を付け、監督の検証結果とは区別する。P0/P1の未達を残したまま全体完了としない。APIや録画環境が阻害した場合は、実装済み部分と未達を明記する。

## P0: 実AIの両経路

- [ ] OpenAI endpointは実際に公式SDKとこのcheckoutのOpenAI adapterを通る。
- [ ] RubyLLM endpointは実際にRubyLLMとこのcheckoutのRubyLLM adapterを通る。
- [ ] 両経路とも `gpt-5.6-luna` / `medium` を実リクエストで使用。別モデルfallbackやmockをlive成功として扱っていない。
- [ ] 同じ用意済み依頼を両経路で完了し、各1ターン内で2種類以上のツールをLLMが選択して実行した証跡がある。
- [ ] tool input→業務処理→output→モデル継続→最終回答が成立し、call ID対応と結果の内容を確認できる。
- [ ] reasoning summaryのイベントとUI表示を実際に観測。トークン数だけでreasoning表示の検証済み判定をしない。未提供なら正直に未達を記録する。
- [ ] API keyはserverのみで使用し、ログ・SSE・HTML・client bundle・DBの証跡・GIF・記事に含まれない。ユーザー.env/swap未変更。

## P1: AgentとGenerative UI

- [ ] 在庫・販売実績・仕入条件のseedとツール結果が対応し、補充計算の数量・価格・単位・リードタイムを説明できる。
- [ ] seedはデモと明記し、外部のリアルタイム在庫・実発注と誤認させない。
- [ ] toolの待機/入力中/結果/失敗がカードで分かり、最終回答と両立する。未知のtoolは安全なfallback表示。
- [ ] OpenAI/RubyLLMをUIで切り替えたときendpoint・会話・cache情報が混線しない。
- [ ] 日本語sidebar/chat/composerが使え、狭い画面でも送信欄・カードを操作できる。
- [ ] テンプレートボタンを押すと編集可能な本文が入り、送信直前に編集できる。毎回手書き不要。
- [ ] 送信中の状態、二重送信防止、停止、新規会話、再生成、エラー後の再試行が適切。
- [ ] raw stateは標準HTML detailsに収まり、通常の会話表示を邪魔しない。
- [ ] 複数ターンで会話contextが保持され、新規会話で他のcontextを引き継がない。

## P1: 永続cacheとstream

- [ ] 同一条件の2回目はcache hitで、provider request増加ゼロを証明できる。
- [ ] Railsプロセス再起動後も同一SQLite DBから結果を再利用できる。
- [ ] 再生成はcacheをbypassしてprovider requestが増え、新たな成功結果でcacheが更新される。
- [ ] adapter/model/reasoning/関連会話/system/tool/seedの違いで誤hitしない。
- [ ] 部分stream、API failure、stop、tool failureを完了成功cacheとして返さない。再生成失敗時の既存cache方針を説明できる。
- [ ] 同時同一依頼でDB制約違反や不完全recordの読出しが起きず、同時別依頼のstreamが混ざらない。
- [ ] SSE headers、開始/step/part/tool/終了の順序、terminalと[DONE]が実useChatで受理される。
- [ ] client disconnectとAPI失敗でstream/接続が閉じ、上限のあるagent loopで終端できる。

## P1: Library

- [ ] lib修正事項がMarkdown依頼票にあり、再現・期待・実際・blocking・修正先・検証方法が揃う。
- [ ] app担当と別のlib担当が修正し、provider-neutral APIの責務を守る。
- [ ] 実在する不具合に対して意味のある回帰テストがあり、RBSと公開API文書が一致する。
- [ ] root suite / lint / RBSと既存の対象exampleの回帰結果がある。既存失敗と今回の失敗を区別する。
- [ ] appの進行を阻む未解決lib依頼がない、または未達として明確。

## P1: 記事・GIF・証拠

- [ ] 冒頭に「Railsで本格的なAI agentを作ってみる」という動機があり、前回記事へ自然につながる。
- [ ] 前回記事本文を取得して参照済み。取得できない場合に読んだと称していない。
- [ ] OpenAI/RubyLLM両経路、複数tool、generative UI、SQLite cache、再生成の実装を説明する。
- [ ] 掲載コードは実ファイルと対応し、説明不要な詳細を省略している。省略を含むコードをそのまま実行可能と誤記しない。
- [ ] 掲載出力は実APIから取得したもの。日時・model・adapter・prompt・run ID・cache状態と元証跡を追える。
- [ ] GIFは実アプリ操作を収録し、送信→複数tool→cards→最終回答が読める。合成画面や静止画だけの疑似動作ではない。
- [ ] 少なくとも1つのGIFはlive応答と対応。cache再生を載せる場合は再生と明記し、両adapterのlive成功は別途証跡で追える。
- [ ] GIFの参照先が存在し、寸法/容量/速度が記事閲覧に適し、キー等が映っていない。
- [ ] 再現手順と.env変数名 `OPENAI_APIKEY` が実装と一致。`published: false`、未公開。
- [ ] 未達・環境制約・取得していないデータを隠さず、検証済みの範囲だけを記事で主張する。

## 報告書共通

- [ ] 変更ファイル、実行コマンド、結果、証跡path、未解決、稼働URL/processが記載されている。
- [ ] 検証時の作業tree状態を追える（commitがなくても差分・対象version等）。
- [ ] 全担当が完了報告後に停止し、次モデルの監督へ引き継げる。
