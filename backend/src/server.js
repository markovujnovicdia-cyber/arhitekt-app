import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { MAX_AUDIO_BYTES, ProxyError, validateAnalysisInput, validateAnalysisOutput, validateAskInput, validateAskOutput } from './contracts.js';
import { createOpenAIProvider } from './provider.js';

function send(response, status, value) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', ...(status === 429 ? { 'Retry-After': '60' } : {}),
  });
  response.end(JSON.stringify(value));
}
function authMatches(header, token) {
  if (typeof header !== 'string' || header.length > 1000 || !header.startsWith('Bearer ')) return false;
  const hash = value => createHash('sha256').update(value).digest();
  return timingSafeEqual(hash(header.slice(7)), hash(token));
}
function readBody(request, maximumBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let rejected = false;
    const chunks = [];
    request.on('data', chunk => {
      if (rejected) return;
      size += chunk.length;
      if (size > maximumBytes) {
        rejected = true;
        chunks.length = 0;
        reject(new ProxyError(413, 'payload_too_large', 'Zahtjev je prevelik. Audio podijelite na manje dijelove.'));
      } else { chunks.push(chunk); }
    });
    request.on('end', () => { if (!rejected) resolve(Buffer.concat(chunks)); });
    request.on('error', () => reject(new ProxyError(400, 'upload_interrupted', 'Prijenos je prekinut. Pokušajte ponovno.')));
    request.on('aborted', () => reject(new ProxyError(400, 'upload_interrupted', 'Prijenos je prekinut. Pokušajte ponovno.')));
  });
}
async function readJSON(request) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) {
    throw new ProxyError(415, 'unsupported_media_type', 'Potreban je JSON zahtjev.');
  }
  const data = await readBody(request, 512 * 1024);
  try { return JSON.parse(data.toString('utf8')); }
  catch { throw new ProxyError(400, 'invalid_json', 'Zahtjev ne sadrži valjan JSON.'); }
}
async function readAudio(request) {
  const contentType = request.headers['content-type'] ?? '';
  if (!/^multipart\/form-data\s*;/i.test(contentType) || contentType.length > 500) {
    throw new ProxyError(415, 'unsupported_media_type', 'Potreban je multipart audio zapis.');
  }
  const data = await readBody(request, MAX_AUDIO_BYTES + 65536);
  let form;
  try {
    form = await new Request('http://internal.invalid', { method: 'POST', headers: { 'Content-Type': contentType }, body: data }).formData();
  } catch { throw new ProxyError(400, 'invalid_multipart', 'Audio zahtjev nije valjan.'); }
  const file = form.get('file');
  const extras = [...form.keys()].filter(key => key !== 'file');
  if (!file || typeof file === 'string' || form.getAll('file').length !== 1 || extras.length || file.size === 0) {
    throw new ProxyError(400, 'invalid_audio', 'Potreban je jedan neprazan audio zapis u polju file.');
  }
  if (file.size > MAX_AUDIO_BYTES) throw new ProxyError(413, 'audio_too_large', 'Audio dio prelazi dopuštenih 20 MiB.');
  if (!/^[^/\\\x00-\x1f]{1,120}\.(m4a|mp4|mp3|mpeg|mpga|wav|flac|ogg|webm)$/i.test(file.name)) {
    throw new ProxyError(400, 'invalid_audio_format', 'Format audio zapisa nije podržan.');
  }
  // The authoritative provider validates codecs. Never write uploads to disk.
  return file;
}

export function createProxyServer({ token, provider, requestsPerMinute = 30, maximumConcurrent = 2 }) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('DEVICE_ACCESS_TOKEN must contain at least32 characters.');
  if (!provider) throw new Error('Missing provider.');
  let active = 0;
  let windowStart = Date.now();
  let requestsInWindow = 0;
  const server = createServer(async (request, response) => {
    let holdsSlot = false;
    try {
      if (request.method === 'GET' && request.url === '/health') {
        send(response, 200, { status: 'ok' });
        return;
      }
      if (!authMatches(request.headers.authorization, token)) {
        request.resume();
        throw new ProxyError(401, 'unauthorized', 'Pristup nije dopušten. Provjerite pristupni token poslužitelja.');
      }
      if (request.method !== 'POST' || !['/v1/transcribe', '/v1/analyze', '/v1/ask'].includes(request.url)) {
        request.resume();
        throw new ProxyError(404, 'not_found', 'Tražena operacija ne postoji.');
      }
      if (Date.now() - windowStart >= 60000) { windowStart = Date.now(); requestsInWindow = 0; }
      if (requestsInWindow >= requestsPerMinute || active >= maximumConcurrent) {
        request.resume();
        throw new ProxyError(429, 'rate_limit', 'Poslužitelj je zauzet. Pokušajte ponovno za jednu minutu.');
      }
      requestsInWindow += 1;
      active += 1;
      holdsSlot = true;
      if (request.url === '/v1/transcribe') {
        const file = await readAudio(request);
        const result = await provider.transcribe(file);
        if (typeof result?.text !== 'string' || result.text.length > 200000) {
          throw new ProxyError(502, 'invalid_transcript', 'AI nije vratio valjan prijepis. Snimka ostaje sačuvana.');
        }
        send(response, 200, { text: result.text });
      } else if (request.url === '/v1/analyze') {
        const input = validateAnalysisInput(await readJSON(request));
        send(response, 200, validateAnalysisOutput(await provider.analyze(input), input));
      } else {
        const input = validateAskInput(await readJSON(request));
        if (input.context.length === 0) {
          send(response, 200, { answer: 'Nema spremljenih podataka koji bi potkrijepili odgovor. Dodajte ili odaberite relevantne projektne zapise.', sourceIDs: [], insufficientData: true });
        } else { send(response, 200, validateAskOutput(await provider.ask(input), input)); }
      }
    } catch (error) {
      if (error instanceof ProxyError) send(response, error.status, { error: { code: error.code, message: error.message } });
      else send(response, 500, { error: { code: 'internal_error', message: 'Obrada nije uspjela. Lokalni podaci ostaju sačuvani.' } });
    } finally { if (holdsSlot) active -= 1; }
  });
  server.requestTimeout = 120000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  return server;
}

export function loadConfiguration(env = process.env) {
  if (!env.OPENAI_API_KEY || !env.DEVICE_ACCESS_TOKEN || env.DEVICE_ACCESS_TOKEN.length < 32) {
    throw new Error('Set OPENAI_API_KEY and DEVICE_ACCESS_TOKEN (at least32 characters) on the backend.');
  }
  const port = Number(env.PORT ?? '8080');
  const timeoutMs = Number(env.PROVIDER_TIMEOUT_MS ?? '120000');
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 300000) {
    throw new Error('Invalid PORT or PROVIDER_TIMEOUT_MS.');
  }
  const transcriptionModel = env.TRANSCRIPTION_MODEL ?? 'gpt-4o-transcribe';
  if (!['gpt-4o-transcribe', 'gpt-4o-mini-transcribe', 'gpt-transcribe'].includes(transcriptionModel)) {
    throw new Error('Unsupported TRANSCRIPTION_MODEL. Check the official provider specification.');
  }
  return {
    host: env.HOST ?? '127.0.0.1', port, token: env.DEVICE_ACCESS_TOKEN,
    provider: createOpenAIProvider({ apiKey: env.OPENAI_API_KEY, transcriptionModel,
      analysisModel: env.ANALYSIS_MODEL ?? 'gpt-4.1-mini', timeoutMs }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const configuration = loadConfiguration();
    const server = createProxyServer(configuration);
    server.listen(configuration.port, configuration.host, () => {
      console.log(`Arhitekt Office backend listening on ${configuration.host}:${configuration.port}`);
    });
    const shutdown = () => { server.close(); server.closeIdleConnections(); };
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
