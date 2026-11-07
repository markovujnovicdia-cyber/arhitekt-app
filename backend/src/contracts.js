import { randomUUID } from 'node:crypto';

export const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
export const MAX_TRANSCRIPT_UNITS = 30000;
export const KINDS = ['note', 'task', 'issue', 'decision', 'question', 'agreement', 'change', 'deadline', 'fact', 'plan', 'summary'];
export const CERTAINTIES = ['confirmed', 'planned', 'proposed', 'uncertain'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class ProxyError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
function requireThat(condition, code = 'invalid_request', message = 'Nevaljan zahtjev.') {
  if (!condition) throw new ProxyError(400, code, message);
}
function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
function boundedString(value, max, nonempty = false) {
  return typeof value === 'string' && value.length <= max && (!nonempty || value.trim().length > 0);
}
function uuid(value) { return typeof value === 'string' && UUID.test(value); }
function noExtraKeys(value, keys) {
  return Object.keys(value).every(key => keys.includes(key));
}

export function validCalendarDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(value + 'T00:00:00.000Z');
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export function validateContext(value) {
  requireThat(Array.isArray(value) && value.length <= 40);
  let total = 0;
  const ids = new Set();
  for (const record of value) {
    requireThat(object(record) && noExtraKeys(record, ['id', 'projectID', 'date', 'title', 'text', 'recordType']));
    requireThat(uuid(record.id) && (record.projectID === undefined || record.projectID === null || uuid(record.projectID)));
    if (record.projectID === undefined) record.projectID = null;
    requireThat(record.recordType === undefined || ['record', 'memory', 'note', 'transcript', 'task', 'issue'].includes(record.recordType));
    requireThat(boundedString(record.date, 40, true) && Number.isFinite(Date.parse(record.date)));
    requireThat(boundedString(record.title, 500) && boundedString(record.text, 12000, true));
    requireThat(!ids.has(record.id.toLowerCase()));
    ids.add(record.id.toLowerCase());
    total += record.text.length + record.title.length;
  }
  requireThat(total <= 80000, 'context_too_large', 'Odaberite manji skup projektnih zapisa.');
  return value;
}

export function validateAnalysisInput(value) {
  requireThat(object(value) && noExtraKeys(value, ['transcript', 'projects', 'context']));
  requireThat(object(value.transcript) && noExtraKeys(value.transcript, ['id', 'text']));
  requireThat(uuid(value.transcript.id) && boundedString(value.transcript.text, MAX_TRANSCRIPT_UNITS, true),
    'transcript_too_large', 'Prijepis mora imati 1–30000 UTF-16 znakova. Podijelite dulji prijepis u dijelove.');
  requireThat(Array.isArray(value.projects) && value.projects.length <= 500);
  const projects = new Set();
  for (const project of value.projects) {
    requireThat(object(project) && noExtraKeys(project, ['id', 'name', 'number']));
    requireThat(uuid(project.id) && boundedString(project.name, 500, true) && boundedString(project.number, 200));
    requireThat(!projects.has(project.id.toLowerCase()));
    projects.add(project.id.toLowerCase());
  }
  validateContext(value.context);
  return value;
}

export function validateAskInput(value) {
  requireThat(object(value) && noExtraKeys(value, ['question', 'context']));
  requireThat(boundedString(value.question, 3000, true));
  validateContext(value.context);
  return value;
}

function outputError() {
  throw new ProxyError(502, 'invalid_provider_output', 'AI je vratio nevaljan ili neutemeljen rezultat. Izvorni podaci ostaju sačuvani.');
}
function checkOutput(condition) { if (!condition) outputError(); }

// The model quotes source text; this service computes real UTF-16 offsets itself.
// No trusting model arithmetic, substring guessing, or fabricated references.
export function validateAnalysisOutput(value, input) {
  checkOutput(object(value) && boundedString(value.summary, 12000));
  checkOutput(Array.isArray(value.proposals) && value.proposals.length <= 100);
  const projects = new Map(input.projects.map(project => [project.id.toLowerCase(), project.id]));
  const contextIDs = new Map(input.context.filter(record => record.recordType === 'memory').map(record => [record.id.toLowerCase(), record.id]));
  const dedup = new Set();
  const proposals = [];
  for (const proposal of value.proposals) {
    checkOutput(object(proposal));
    checkOutput(proposal.projectID === null || (uuid(proposal.projectID) && projects.has(proposal.projectID.toLowerCase())));
    checkOutput(KINDS.includes(proposal.kind) && CERTAINTIES.includes(proposal.certainty));
    checkOutput(boundedString(proposal.title, 500, true) && boundedString(proposal.details, 12000, true));
    checkOutput(proposal.responsible === null || boundedString(proposal.responsible, 300, true));
    checkOutput(proposal.dueDate === null || validCalendarDate(proposal.dueDate));
    checkOutput(proposal.relatedEntryID === null || (uuid(proposal.relatedEntryID) && contextIDs.has(proposal.relatedEntryID.toLowerCase())));
    checkOutput(object(proposal.source) && uuid(proposal.source.transcriptID) && proposal.source.transcriptID.toLowerCase() === input.transcript.id.toLowerCase());
    const quote = proposal.source.quote;
    checkOutput(boundedString(quote, MAX_TRANSCRIPT_UNITS, true));
    const startUTF16 = input.transcript.text.indexOf(quote);
    checkOutput(startUTF16 >= 0);
    // Repeated identical phrases cannot be assigned unambiguously: fail closed.
    checkOutput(input.transcript.text.indexOf(quote, startUTF16 + 1) === -1);
    const endUTF16 = startUTF16 + quote.length;
    checkOutput(input.transcript.text.slice(startUTF16, endUTF16) === quote);
    const projectID = proposal.projectID === null ? null : projects.get(proposal.projectID.toLowerCase());
    const relatedEntryID = proposal.relatedEntryID === null ? null : contextIDs.get(proposal.relatedEntryID.toLowerCase());
    const key = [projectID, proposal.kind, startUTF16, endUTF16].join(':');
    if (dedup.has(key)) continue;
    dedup.add(key);
    proposals.push({
      id: randomUUID(), projectID, kind: proposal.kind,
      certainty: proposal.certainty, title: proposal.title, details: proposal.details,
      responsible: proposal.responsible, dueDate: proposal.dueDate,
      source: { transcriptID: input.transcript.id, startUTF16, endUTF16, quote },
      relatedEntryID,
    });
  }
  return { summary: value.summary, proposals };
}

export function validateAskOutput(value, input) {
  checkOutput(object(value) && boundedString(value.answer, 16000, true));
  checkOutput(typeof value.insufficientData === 'boolean' && Array.isArray(value.sourceIDs));
  checkOutput(value.sourceIDs.length <= input.context.length);
  const ids = new Map(input.context.map(record => [record.id.toLowerCase(), record.id]));
  checkOutput(value.sourceIDs.every(id => uuid(id) && ids.has(id.toLowerCase())));
  const sourceIDs = [...new Set(value.sourceIDs.map(id => ids.get(id.toLowerCase())))];
  checkOutput(value.insufficientData || sourceIDs.length > 0);
  return { answer: value.answer, sourceIDs, insufficientData: value.insufficientData };
}

const nullableString = { type: ['string', 'null'] };
export const ANALYSIS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['summary', 'proposals'],
  properties: {
    summary: { type: 'string' },
    proposals: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['projectID', 'kind', 'certainty', 'title', 'details', 'responsible', 'dueDate', 'source', 'relatedEntryID'],
      properties: {
        projectID: nullableString, kind: { type: 'string', enum: KINDS },
        certainty: { type: 'string', enum: CERTAINTIES }, title: { type: 'string' },
        details: { type: 'string' }, responsible: nullableString, dueDate: nullableString,
        relatedEntryID: nullableString,
        source: { type: 'object', additionalProperties: false,
          required: ['transcriptID', 'quote'],
          properties: { transcriptID: { type: 'string' }, quote: { type: 'string' } },
        },
      },
    } },
  },
};
export const ASK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['answer', 'sourceIDs', 'insufficientData'],
  properties: {
    answer: { type: 'string' }, sourceIDs: { type: 'array', items: { type: 'string' } },
    insufficientData: { type: 'boolean' },
  },
};
