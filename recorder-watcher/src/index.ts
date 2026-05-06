import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import chokidar from 'chokidar';

/**
 * Closerfy Media Edge — Recorder Watcher
 *
 * Vigia o diretório de gravações do Janus. Quando um arquivo `.mjr`
 * (formato proprietário Janus) está finalizado (sem mais escritas por N
 * segundos), converte pra `.ogg` (Opus) e POSTa pro backend Closerfy
 * com o `callId` extraído do nome do arquivo.
 *
 * Padrão de nome esperado: `wa-<callId>-<timestamp>-audio.mjr`
 * (definido em JanusClientService.createCallSession do backend Closerfy)
 *
 * Fluxo:
 *   .mjr fechado ─→ ffmpeg convert ─→ POST /whatsapp/calls/internal/recording-ready
 *                                       (multipart com audio + callId)
 */

const RECORDINGS_DIR = process.env.RECORDINGS_DIR || '/recordings';
const BACKEND_URL = process.env.CLOSERFY_BACKEND_URL || 'https://api.closerfy.ai';
const INGEST_TOKEN = process.env.CLOSERFY_INGEST_TOKEN;

const SETTLE_MS = 5_000; // espera 5s sem mudança no arquivo antes de processar
const MAX_RETRIES = 3;

if (!INGEST_TOKEN) {
  console.error('FATAL: CLOSERFY_INGEST_TOKEN não configurado');
  process.exit(1);
}

const settling = new Map<string, NodeJS.Timeout>();
const processed = new Set<string>();

function callIdFromPath(p: string): string | null {
  // Esperado: /recordings/wa-<callId>-<timestamp>-audio.mjr
  const base = path.basename(p);
  const match = base.match(/^wa-([^-]+)-/);
  return match ? match[1] : null;
}

function postProcess(mjrPath: string) {
  if (processed.has(mjrPath)) return;
  const callId = callIdFromPath(mjrPath);
  if (!callId) {
    console.warn(`[skip] arquivo sem callId no nome: ${mjrPath}`);
    return;
  }

  processed.add(mjrPath);
  const oggPath = mjrPath.replace(/\.mjr$/, '.ogg');

  console.log(`[convert] ${mjrPath} → ${oggPath} (callId=${callId})`);

  // Janus distribui um pós-processador (janus-pp-rec) que converte .mjr pra .opus.
  // Como não está disponível na imagem alpine, usamos ffmpeg direto:
  // os .mjr de áudio Opus são frames Opus brutos com header Janus, ffmpeg lê.
  // Se o conversor nativo do Janus estiver disponível, usar ele pode dar
  // melhor qualidade — substituir esse spawn por janus-pp-rec.
  const ff = spawn('ffmpeg', [
    '-y',
    '-i', mjrPath,
    '-c:a', 'libopus',
    '-b:a', '32k',
    '-ar', '48000',
    '-ac', '1',
    oggPath,
  ]);

  let stderr = '';
  ff.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });

  ff.on('close', async (code) => {
    if (code !== 0) {
      console.error(`[ffmpeg-fail] code=${code} stderr=${stderr.slice(-500)}`);
      processed.delete(mjrPath);
      return;
    }
    if (!fs.existsSync(oggPath)) {
      console.error(`[ffmpeg-fail] arquivo não criado: ${oggPath}`);
      processed.delete(mjrPath);
      return;
    }

    try {
      await uploadToBackend(callId, oggPath);
      console.log(`[uploaded] callId=${callId} ${oggPath}`);
    } catch (err) {
      console.error(`[upload-fail] callId=${callId}:`, (err as Error).message);
      processed.delete(mjrPath);
    }
  });
}

async function uploadToBackend(callId: string, oggPath: string, attempt = 1): Promise<void> {
  const buf = fs.readFileSync(oggPath);
  const blob = new Blob([buf], { type: 'audio/ogg' });

  const form = new FormData();
  form.append('callId', callId);
  form.append('audio', blob, path.basename(oggPath));

  try {
    const res = await fetch(`${BACKEND_URL}/api/v1/whatsapp/calls/internal/recording-ready`, {
      method: 'POST',
      headers: {
        'X-Ingest-Token': INGEST_TOKEN!,
      },
      body: form,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
    }
  } catch (err) {
    if (attempt < MAX_RETRIES) {
      const backoff = 2_000 * attempt;
      console.warn(`[retry] callId=${callId} attempt=${attempt} em ${backoff}ms`);
      await new Promise((r) => setTimeout(r, backoff));
      return uploadToBackend(callId, oggPath, attempt + 1);
    }
    throw err;
  }
}

function scheduleProcess(mjrPath: string) {
  // Cancela timer anterior — arquivo ainda recebendo writes
  const prev = settling.get(mjrPath);
  if (prev) clearTimeout(prev);

  const timer = setTimeout(() => {
    settling.delete(mjrPath);
    postProcess(mjrPath);
  }, SETTLE_MS);

  settling.set(mjrPath, timer);
}

console.log(`[start] watching ${RECORDINGS_DIR} → POST ${BACKEND_URL}`);

const watcher = chokidar.watch(`${RECORDINGS_DIR}/*.mjr`, {
  persistent: true,
  ignoreInitial: false,
  awaitWriteFinish: false,
});

watcher.on('add', (p) => {
  console.log(`[detected] ${p}`);
  scheduleProcess(p);
});

watcher.on('change', (p) => {
  scheduleProcess(p);
});

watcher.on('error', (err) => {
  console.error('[watcher-error]', err);
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('[shutdown] SIGINT');
  watcher.close().then(() => process.exit(0));
});
process.on('SIGTERM', () => {
  console.log('[shutdown] SIGTERM');
  watcher.close().then(() => process.exit(0));
});
