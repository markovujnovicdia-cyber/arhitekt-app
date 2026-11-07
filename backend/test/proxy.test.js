import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createProxyServer, loadConfiguration } from '../src/server.js';
import { createOpenAIProvider } from '../src/provider.js';
import { MAX_AUDIO_BYTES, validateAnalysisOutput, validCalendarDate } from '../src/contracts.js';

const token = 'test-device-token-not-a-secret-0123456789';
const tid = '10000000-0000-4000-8000-000000000001';
const pid = '20000000-0000-4000-8000-000000000002';
const eid = '30000000-0000-4000-8000-000000000003';
const text = 'Kuća Cerje. Trebam nazvati statičara. Problem je vlasnički list.';
const input = () => ({ transcript: { id: tid, text }, projects: [{ id: pid, name: 'Kuća Cerje', number: '2026-1' }], context: [] });
const proposal = (quote = 'Trebam nazvati statičara.') => ({
  projectID: pid, kind: 'task', certainty: 'planned', title: 'Nazvati statičara', details: 'Trebam nazvati statičara.',
  responsible: null, dueDate: null, source: { transcriptID: tid, quote }, relatedEntryID: null,
});
const analysis = () => ({ summary: 'Potreban je poziv statičaru.', proposals: [proposal()] });
const source = () => ({ id: eid, projectID: pid, date: '2026-11-07T08:00:00Z', title: 'Dogovor', text: 'Investitor želi pregled u petak.' });
async function running(t, provider = {}, options = {}) {
  const defaults = {
    transcribe: async () => ({ text: 'Cjeloviti prijepis.' }),
    analyze: async () => analysis(),
    ask: async () => ({ answer: 'Investitor želi pregled u petak.', sourceIDs: [eid], insufficientData: false }),
  };
  const server = createProxyServer({ token, provider: { ...defaults, ...provider }, ...options });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const origin = `http://127.0.0.1:${server.address().port}`;
  return {
    origin,
    post: (path, value, authorization = `Bearer ${token}`) => fetch(origin + path, {
      method: 'POST', headers: { Authorization: authorization, 'Content-Type': 'application/json' }, body: JSON.stringify(value),
    }),
    audio: async (file, name = 'chunk.m4a') => {
      const body = new FormData(); body.set('file', new Blob([file], { type: 'audio/mp4' }), name);
      return fetch(origin + '/v1/transcribe', { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body });
    },
  };
}

test('health is unauthenticated and discloses no configuration', async t => {
  const app = await running(t);
  const response = await fetch(app.origin + '/health');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { status: 'ok' });
});
test('authenticated API rejects missing or incorrect bearer token', async t => {
  const app = await running(t);
  const response = await app.post('/v1/analyze', input(), 'Bearer incorrect');
  assert.equal(response.status, 401);
});
test('analysis returns canonical source offsets and a fresh UUID', async t => {
  const app = await running(t);
  const response = await app.post('/v1/analyze', input());
  assert.equal(response.status, 200);
  const result = await response.json();
  const item = result.proposals[0];
  assert.match(item.id, /^[0-9a-f-]{36}$/);
  assert.equal(text.slice(item.source.startUTF16, item.source.endUTF16), item.source.quote);
  assert.equal(item.source.startUTF16, text.indexOf('Trebam'));
});
test('UTF16 source indices remain correct after surrogate pairs', () => {
  const request = input(); request.transcript.text = '🏠 Projekt. Trebam nazvati statičara.';
  const result = validateAnalysisOutput(analysis(), request);
  const ref = result.proposals[0].source;
  assert.equal(ref.startUTF16, 12);
  assert.equal(request.transcript.text.slice(ref.startUTF16, ref.endUTF16), ref.quote);
});
test('provider source offsets are ignored and recomputed from actual quote', () => {
  const value = analysis(); value.proposals[0].source.startUTF16 = 100000;
  assert.equal(validateAnalysisOutput(value, input()).proposals[0].source.startUTF16, 12);
});
test('duplicate provider proposals do not produce duplicate writes', async t => {
  const value = analysis(); value.proposals.push(proposal());
  const app = await running(t, { analyze: async () => value });
  const response = await app.post('/v1/analyze', input());
  assert.equal((await response.json()).proposals.length, 1);
});
test('fabricated quotes or transcript IDs are rejected', async t => {
  const app = await running(t, { analyze: async () => ({ summary: '', proposals: [proposal('Nema takve rečenice.')] }) });
  const response = await app.post('/v1/analyze', input());
  assert.equal(response.status, 502);
  assert.equal((await response.json()).error.code, 'invalid_provider_output');
});
test('ambiguous repeated quotes fail rather than guessing their source location', () => {
  const request = input(); request.transcript.text += ' Trebam nazvati statičara.';
  assert.throws(() => validateAnalysisOutput(analysis(), request));
});
test('unrecognized projects and invented related entries are rejected', () => {
  const value = analysis(); value.proposals[0].projectID = eid;
  assert.throws(() => validateAnalysisOutput(value, input()));
  value.proposals[0].projectID = pid; value.proposals[0].relatedEntryID = eid;
  assert.throws(() => validateAnalysisOutput(value, input()));
});
test('invalid calendar dates do not silently roll into another month', () => {
  assert.equal(validCalendarDate('2026-02-29'), false);
  assert.equal(validCalendarDate('2028-02-29'), true);
  assert.equal(validCalendarDate('2026-13-01'), false);
  const value = analysis(); value.proposals[0].dueDate = '2026-02-30';
  assert.throws(() => validateAnalysisOutput(value, input()));
});
test('long transcript fragment preserves quote near the end', async t => {
  const request = input(); request.transcript.text = 'Dugi sastanak. '.repeat(1900) + 'Trebam nazvati statičara.';
  const app = await running(t);
  const response = await app.post('/v1/analyze', request);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.proposals[0].source.endUTF16, request.transcript.text.length);
});
test('oversized fragment and invalid UUID fail before provider execution', async t => {
  let calls = 0;
  const app = await running(t, { analyze: async () => { calls++; return analysis(); } });
  const request = input(); request.transcript.text = 'x'.repeat(30001);
  assert.equal((await app.post('/v1/analyze', request)).status, 400);
  request.transcript.text = text; request.transcript.id = 'not-a-uuid';
  assert.equal((await app.post('/v1/analyze', request)).status, 400);
  assert.equal(calls, 0);
});
test('malformed JSON is rejected without echoing request data', async t => {
  const app = await running(t);
  const response = await fetch(app.origin + '/v1/analyze', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{"confidential-meeting":' });
  assert.equal(response.status, 400);
  assert.equal((await response.text()).includes('confidential-meeting'), false);
});
test('ask with empty context returns explicit insufficient-data answer without AI call', async t => {
  const app = await running(t, { ask: async () => { throw new Error('must not call provider'); } });
  const response = await app.post('/v1/ask', { question: 'Što smo dogovorili?', context: [] });
  const answer = await response.json();
  assert.equal(response.status, 200);
  assert.equal(answer.insufficientData, true);
  assert.deepEqual(answer.sourceIDs, []);
});
test('ask only returns existing context source IDs', async t => {
  const app = await running(t);
  const response = await app.post('/v1/ask', { question: 'Što želi investitor?', context: [source()] });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).sourceIDs, [eid]);
});
test('ask rejects fabricated citations and unsupported sufficient answer', async t => {
  const app = await running(t, { ask: async () => ({ answer: 'Izmišljeno.', sourceIDs: [pid], insufficientData: false }) });
  assert.equal((await app.post('/v1/ask', { question: 'Dogovor?', context: [source()] })).status, 502);
});
test('transcription forwards complete multipart file and preserves request sequence', async t => {
  const received = [];
  const app = await running(t, { transcribe: async file => {
    received.push(Buffer.from(await file.arrayBuffer()).toString());
    return { text: `Prijepis ${received.length}` };
  } });
  assert.equal((await (await app.audio('first-audio-chunk')).json()).text, 'Prijepis 1');
  assert.equal((await (await app.audio('second-audio-chunk')).json()).text, 'Prijepis 2');
  assert.deepEqual(received, ['first-audio-chunk', 'second-audio-chunk']);
});
test('empty audio and unsupported formats fail before upload to provider', async t => {
  const app = await running(t);
  assert.equal((await app.audio('')).status, 400);
  assert.equal((await app.audio('data', 'audio.exe')).status, 400);
});
test('audio over20MiB is rejected', async t => {
  const app = await running(t);
  assert.equal((await app.audio(new Uint8Array(MAX_AUDIO_BYTES + 1))).status, 413);
});
test('rate limit uses429 and Retry-After', async t => {
  const app = await running(t, {}, { requestsPerMinute: 1 });
  assert.equal((await app.post('/v1/analyze', input())).status, 200);
  const response = await app.post('/v1/analyze', input());
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '60');
});
test('unexpected provider exceptions reveal neither upstream detail nor token', async t => {
  const app = await running(t, { analyze: async () => { throw new Error('secret-user-text ' + token); } });
  const response = await app.post('/v1/analyze', input());
  assert.equal(response.status, 500);
  const body = await response.text();
  assert.equal(body.includes('secret-user-text'), false);
  assert.equal(body.includes(token), false);
});
test('OpenAI adapter requests Croatian JSON and does not expose upstream error body', async () => {
  let sent;
  const provider = createOpenAIProvider({ apiKey: 'not-a-real-key', fetchImpl: async (url, options) => {
    sent = options;
    return new Response(JSON.stringify({ text: 'Dobar dan.' }), { status: 200 });
  } });
  const result = await provider.transcribe(new File(['audio'], 'chunk.m4a'));
  assert.equal(result.text, 'Dobar dan.');
  assert.equal(sent.body.get('language'), 'hr');
  assert.equal(sent.body.get('response_format'), 'json');
  assert.equal(sent.body.get('model'), 'gpt-4o-transcribe');
  const limited = createOpenAIProvider({ apiKey: 'key', fetchImpl: async () => new Response('private-error-detail', { status: 429 }) });
  await assert.rejects(limited.transcribe(new File(['a'], 'a.m4a')), error => error.status === 429 && !error.message.includes('private-error-detail'));
});
test('provider malformed JSON, refusal and truncated answers are explicit errors', async () => {
  const malformed = createOpenAIProvider({ apiKey: 'key', fetchImpl: async () => new Response('not-json') });
  await assert.rejects(malformed.transcribe(new File(['a'], 'a.m4a')), error => error.code === 'invalid_provider_output');
  const refused = createOpenAIProvider({ apiKey: 'key', fetchImpl: async () => Response.json({ choices: [{ finish_reason: 'stop', message: { refusal: 'no', content: null } }] }) });
  await assert.rejects(refused.analyze(input()), error => error.code === 'incomplete_provider_output');
  const truncated = createOpenAIProvider({ apiKey: 'key', fetchImpl: async () => Response.json({ choices: [{ finish_reason: 'length', message: { content: '{}' } }] }) });
  await assert.rejects(truncated.analyze(input()), error => error.code === 'incomplete_provider_output');
});
test('timeouts and network errors are sanitized and keep provider configuration private', async () => {
  const provider = createOpenAIProvider({ apiKey: 'secret', fetchImpl: async () => { throw new Error('secret internal network'); } });
  await assert.rejects(provider.transcribe(new File(['a'], 'a.m4a')), error => error.status === 503 && !error.message.includes('secret'));
});
test('production configuration refuses absent keys and short device tokens', () => {
  assert.throws(() => loadConfiguration({}));
  assert.throws(() => loadConfiguration({ OPENAI_API_KEY: 'some-key', DEVICE_ACCESS_TOKEN: 'short' }));
  const config = loadConfiguration({ OPENAI_API_KEY: 'some-key', DEVICE_ACCESS_TOKEN: token });
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 8080);
});

test('analysis links only memory context records, not arbitrary transcript/task sources', () => {
  const request = input(); request.context = [{ ...source(), recordType: 'task' }];
  const value = analysis(); value.proposals[0].relatedEntryID = eid;
  assert.throws(() => validateAnalysisOutput(value, request));
  request.context[0].recordType = 'memory';
  assert.equal(validateAnalysisOutput(value, request).proposals[0].relatedEntryID, eid);
});

test('Swift Codable omitted nil projectID is accepted for unassigned source records', async t => {
  const record = source(); delete record.projectID;
  const app = await running(t);
  const response = await app.post('/v1/ask', { question: 'Dogovor?', context: [record] });
  assert.equal(response.status, 200);
});

test('UUID source and project identity is case-insensitive without accepting unknown UUIDs', () => {
  const request = input();
  request.transcript.id = 'ABCD0000-0000-4000-8000-000000000001';
  request.projects[0].id = 'ABCD0000-0000-4000-8000-000000000002';
  const value = analysis();
  value.proposals[0].projectID = request.projects[0].id.toLowerCase();
  value.proposals[0].source.transcriptID = request.transcript.id.toLowerCase();
  const result = validateAnalysisOutput(value, request);
  assert.equal(result.proposals[0].projectID, request.projects[0].id);
  assert.equal(result.proposals[0].source.transcriptID, request.transcript.id);
});
