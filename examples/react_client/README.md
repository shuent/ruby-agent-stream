# AI SDK `useChat` verification client

This Vite/React application consumes the provider-neutral Rails example's real
UI Message Stream Protocol response with `@ai-sdk/react`'s `useChat`. There is
no custom stream parser or message-state reducer.

Start `../rails_demo` on `127.0.0.1:3000`, then run:

```bash
npm install
npm test
npm run build
npm run dev
```

Open `http://127.0.0.1:5173` and use the complete, error, and slow/cancel
controls. The page exposes stable `data-testid` hooks for browser automation and
shows both accumulated `UIMessage` parts and hook callbacks.
