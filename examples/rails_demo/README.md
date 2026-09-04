# Minimal Rails streaming server

This Rails 8.1 application demonstrates `RubyLLM::Stream::AISDK` over a real
`ActionController::Live` response. It does not call an AI API:
`DemoConversation` builds deterministic RubyLLM chunks and typed agent events.

```bash
bundle install
bin/rails test
bin/rails server -b 127.0.0.1 -p 3000
```

Inspect the raw protocol:

```bash
curl -N -X POST \
  -H 'Content-Type: application/json' \
  --data '{"scenario":"complete"}' \
  http://127.0.0.1:3000/chat
```

Supported scenarios are `complete`, `abort`, `error`, and `slow`. The React client in
`../react_client` proxies `/chat` to port 3000 and exercises all four with
`useChat`.

The controller sets protocol headers before its first write, treats browser
disconnects as expected cancellation, and closes `response.stream` in an
`ensure` block.
