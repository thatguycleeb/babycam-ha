'use strict';
// Turns the camera's JPEG frames + 16 kHz PCM into an H.264/AAC MPEG-TS stream
// (/stream.ts) for Home Assistant's Generic Camera, go2rtc and HomeKit Bridge.
//
// ffmpeg only runs while someone is reading the stream. This module is the clock:
// it feeds exactly OUT_FPS frames a second (repeating the latest frame, or a blank
// one while the phone is offline) and a continuous audio track (padding gaps with
// silence). ffmpeg just counts frames and samples, so audio and video stay in sync
// and HA / HomeKit never see a stalled stream.

const { spawn, execFileSync } = require('child_process');
const net = require('net');

const SAMPLE_RATE = 16000;
const OUT_WIDTH = 1280;
const OUT_HEIGHT = 720;
const OUT_FPS = 15;
const STOP_AFTER_IDLE_MS = 15000;
const MAX_CLIENT_BACKLOG = 4 * 1024 * 1024;
const AUDIO_LEAD_SAMPLES = SAMPLE_RATE / 10;        // keep ~100 ms of audio queued
const AUDIO_PAD_AFTER_SAMPLES = SAMPLE_RATE * 3 / 10; // pad once we're 300 ms short
const AUDIO_MAX_AHEAD_SAMPLES = SAMPLE_RATE;        // drop audio more than 1 s ahead

function findFfmpeg() {
  const bin = process.env.FFMPEG_PATH || 'ffmpeg';
  try {
    execFileSync(bin, ['-hide_banner', '-version'], { stdio: 'ignore' });
    return bin;
  } catch {
    return null;
  }
}

class TsStream {
  constructor(log) {
    this.log = log;
    this.ffmpeg = findFfmpeg();
    this.clients = new Set();
    this.onClientsChange = () => {};
    this.proc = null;
    this.audioServer = null;
    this.audioSocket = null;
    this.cameraOnline = false;
    this.lastFrame = null;
    this.clockStart = 0;
    this.framesWritten = 0;
    this.samplesWritten = 0;
    this.stopTimer = null;
    this.tickTimer = null;
    this.placeholder = this.ffmpeg ? this.makePlaceholder() : null;
    if (!this.ffmpeg) log('ffmpeg not found; /stream.ts (HA camera with sound, HomeKit) is disabled.');
  }

  get available() {
    return !!this.ffmpeg && !!this.placeholder;
  }

  makePlaceholder() {
    try {
      return execFileSync(this.ffmpeg, [
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', `color=c=0x0b0d10:s=${OUT_WIDTH}x${OUT_HEIGHT}`,
        '-frames:v', '1', '-f', 'mjpeg', 'pipe:1',
      ]);
    } catch (e) {
      this.log(`Could not create placeholder frame: ${e.message}`);
      return null;
    }
  }

  // ---- Input from the camera -------------------------------------------------

  setCameraOnline(online) {
    this.cameraOnline = online;
    if (!online) this.lastFrame = null;
  }

  pushFrame(jpeg) {
    this.lastFrame = jpeg;
  }

  pushAudio(pcm) {
    if (!this.audioSocket) return;
    if (this.samplesWritten - this.samplesDue() > AUDIO_MAX_AHEAD_SAMPLES) return;
    this.writeAudio(pcm);
  }

  // ---- Clock ---------------------------------------------------------------

  samplesDue() {
    return Math.floor((Date.now() - this.clockStart) * SAMPLE_RATE / 1000);
  }

  writeAudio(pcm) {
    if (this.audioSocket.writableLength > 512 * 1024) return;
    this.audioSocket.write(pcm);
    this.samplesWritten += pcm.length >> 1;
  }

  tick() {
    const stdin = this.proc && this.proc.stdin;
    if (!stdin || stdin.destroyed) return;

    // Video: one frame per 1/OUT_FPS s. If we fell far behind (e.g. a GC pause), skip ahead.
    const framesDue = Math.floor((Date.now() - this.clockStart) * OUT_FPS / 1000);
    if (framesDue - this.framesWritten > OUT_FPS) this.framesWritten = framesDue - 1;
    const frame = (this.cameraOnline && this.lastFrame) || this.placeholder;
    while (this.framesWritten < framesDue) {
      if (stdin.writableLength < 4 * 1024 * 1024) stdin.write(frame);
      this.framesWritten += 1;
    }

    // Audio: pad with silence when the phone's audio stalls or is missing.
    if (this.audioSocket) {
      const due = this.samplesDue();
      if (due - this.samplesWritten > AUDIO_PAD_AFTER_SAMPLES) {
        const missing = Math.min(due + AUDIO_LEAD_SAMPLES - this.samplesWritten, SAMPLE_RATE * 2);
        this.writeAudio(Buffer.alloc(missing * 2));
      }
    }
  }

  // ---- Clients -------------------------------------------------------------

  addClient(req, res) {
    res.writeHead(200, {
      'Content-Type': 'video/mp2t',
      'Cache-Control': 'no-store',
      Connection: 'close',
    });
    this.clients.add(res);
    clearTimeout(this.stopTimer);
    this.start();
    this.onClientsChange();
    req.on('close', () => {
      this.clients.delete(res);
      this.onClientsChange();
      if (this.clients.size === 0) {
        clearTimeout(this.stopTimer);
        this.stopTimer = setTimeout(() => this.stop(), STOP_AFTER_IDLE_MS);
      }
    });
  }

  broadcast(chunk) {
    for (const res of this.clients) {
      if (res.writableLength < MAX_CLIENT_BACKLOG) res.write(chunk);
    }
  }

  // ---- ffmpeg --------------------------------------------------------------

  start() {
    if (this.proc || this.audioServer || !this.available) return;

    // Audio goes in over a loopback socket (a second pipe isn't portable).
    const server = net.createServer((socket) => {
      socket.on('error', () => {});
      this.audioSocket = socket;
      this.samplesWritten = 0;
    });
    server.on('error', (e) => this.log(`Stream audio socket error: ${e.message}`));
    this.audioServer = server;

    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      const vf = [
        `scale=${OUT_WIDTH}:${OUT_HEIGHT}:force_original_aspect_ratio=decrease`,
        `pad=${OUT_WIDTH}:${OUT_HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black`,
        'setsar=1',
        'format=yuv420p',
      ].join(',');

      const args = [
        '-hide_banner', '-loglevel', process.env.BABYCAM_FFMPEG_LOGLEVEL || 'error', '-nostdin',
        // video: constant-rate JPEG frames on stdin
        '-probesize', '32', '-analyzeduration', '0',
        '-f', 'mjpeg', '-framerate', String(OUT_FPS), '-i', 'pipe:0',
        // audio: continuous raw PCM from the loopback socket
        '-f', 's16le', '-ar', String(SAMPLE_RATE), '-ac', '1', '-i', `tcp://127.0.0.1:${port}`,
        '-map', '0:v', '-map', '1:a',
        '-vf', vf, '-r', String(OUT_FPS),
        '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency',
        '-profile:v', 'main', '-level:v', '4.0',
        '-g', String(OUT_FPS * 2), '-keyint_min', String(OUT_FPS * 2), '-sc_threshold', '0',
        '-b:v', '1500k', '-maxrate', '2000k', '-bufsize', '3000k',
        '-c:a', 'aac', '-b:a', '48k', '-ar', String(SAMPLE_RATE), '-ac', '1',
        '-f', 'mpegts', '-muxdelay', '0', '-muxpreload', '0', '-flush_packets', '1',
        'pipe:1',
      ];

      const proc = spawn(this.ffmpeg, args, { stdio: ['pipe', 'pipe', 'pipe'] });
      this.proc = proc;
      this.clockStart = Date.now();
      this.framesWritten = 0;
      this.samplesWritten = 0;
      proc.stdin.on('error', () => {});
      proc.stdout.on('data', (chunk) => this.broadcast(chunk));
      proc.stderr.on('data', (d) => this.log(`ffmpeg: ${d.toString().trim()}`));
      proc.on('exit', (code, signal) => {
        if (this.proc !== proc) return;
        this.cleanup();
        if (this.clients.size > 0) {
          this.log(`ffmpeg exited (${signal || code}); restarting.`);
          setTimeout(() => this.start(), 1000);
        }
      });

      this.tickTimer = setInterval(() => this.tick(), 20);
      this.log('Stream encoder started.');
    });
  }

  cleanup() {
    clearInterval(this.tickTimer);
    this.tickTimer = null;
    if (this.audioSocket) this.audioSocket.destroy();
    if (this.audioServer) this.audioServer.close();
    this.audioSocket = null;
    this.audioServer = null;
    this.proc = null;
  }

  stop() {
    if (!this.proc) return;
    const proc = this.proc;
    this.cleanup();
    proc.kill('SIGTERM');
    for (const res of this.clients) res.end();
    this.log('Stream encoder stopped (no viewers).');
  }
}

module.exports = TsStream;
