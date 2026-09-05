// Uses the example's installed SDK, with a fake HTTP transport and real Ruby SSE.
// Run from the repository root: node test/integration/approval_continuation.mjs
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Chat } from '../../examples/react_client/node_modules/@ai-sdk/react/dist/index.js';
import {
  DefaultChatTransport,
  lastAssistantMessageIsCompleteWithApprovalResponses,
} from '../../examples/react_client/node_modules/ai/dist/index.js';

const root = fileURLToPath(new URL('../..', import.meta.url));
const fixture = JSON.parse(execFileSync('bundle', ['exec', 'ruby', 'test/integration/approval_frames.rb'], {
  cwd: root, encoding: 'utf8',
}));

for (const approved of [true, false]) {
  const requests = [];
  const errors = [];
  let finishCount = 0;
  let resolveContinuation;
  const continued = new Promise(resolve => { resolveContinuation = resolve; });
  const chat = new Chat({
    id: 'conversation-1',
    sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithApprovalResponses,
    onError: error => { errors.push(error); resolveContinuation(); },
    onFinish: () => { if (++finishCount === 2) resolveContinuation(); },
    transport: new DefaultChatTransport({
      api: 'http://fixture.invalid/chat',
      fetch: async (_url, options) => {
        assert.equal(options.method, 'POST');
        requests.push(JSON.parse(options.body));
        assert.ok(requests.length <= 2, 'approval must make exactly one continuation request');
        return new Response(requests.length === 1 ? fixture.initial : fixture.responses[String(approved)], {
          headers: { 'content-type': 'text/event-stream', 'x-vercel-ai-ui-message-stream': 'v1' },
        });
      },
    }),
  });
  await chat.sendMessage({ text: 'Write three items.' });
  assert.equal(requests.length, 1);
  assert.equal(chat.status, 'ready');
  assert.equal(chat.messages.at(-1).parts.find(part => part.toolCallId)?.state, 'approval-requested');
  await chat.addToolApprovalResponse({ id: 'approval-write', approved });
  let timer;
  await Promise.race([
    continued,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('continuation timeout')), 3000); }),
  ]).finally(() => clearTimeout(timer));
  assert.deepEqual(errors, []);
  assert.equal(requests.length, 2);
  const sent = requests[1].messages.at(-1);
  assert.equal(sent.id, 'assistant-approval');
  assert.equal(sent.parts.find(part => part.toolCallId).state, 'approval-responded');
  assert.equal(sent.parts.find(part => part.toolCallId).approval.approved, approved);
  assert.equal(chat.messages.length, 2, 'continuation must retain one assistant message');
  assert.equal(chat.messages.at(-1).id, sent.id);
  const tools = chat.messages.at(-1).parts.filter(part => part.toolCallId);
  assert.equal(tools.length, 1);
  assert.equal(tools[0].toolCallId, 'call-write');
  assert.equal(tools[0].state, approved ? 'output-available' : 'output-denied');
}
console.log('PASS: approval + denial; each uses 2 HTTP requests, 1 assistant, 1 tool; no network/API');
