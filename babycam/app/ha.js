'use strict';
// Publishes BabyCam sensors to Home Assistant through the Supervisor API.

const fs = require('fs');

function readToken() {
  if (process.env.SUPERVISOR_TOKEN) return process.env.SUPERVISOR_TOKEN;
  try {
    return fs.readFileSync('/run/s6/container_environment/SUPERVISOR_TOKEN', 'utf8').trim();
  } catch {
    return '';
  }
}

class HomeAssistant {
  constructor(log) {
    this.log = log;
    this.token = readToken();
    this.state = { camera: false, noise: false, level: null };
    this.warned = false;
    if (this.token) {
      this.pushAll();
      // Re-publish every minute so the sensors come back after a Home Assistant restart.
      setInterval(() => this.pushAll(), 60_000);
    }
  }

  get enabled() {
    return !!this.token;
  }

  setCamera(online) {
    this.state.camera = online;
    this.push('binary_sensor.babycam_camera', online ? 'on' : 'off', {
      friendly_name: 'BabyCam camera',
      device_class: 'connectivity',
    });
  }

  setNoise(on) {
    this.state.noise = on;
    this.push('binary_sensor.babycam_noise', on ? 'on' : 'off', {
      friendly_name: 'BabyCam noise',
      device_class: 'sound',
    });
  }

  setLevel(db) {
    this.state.level = db;
    this.push('sensor.babycam_sound_level', db === null ? 'unavailable' : db, {
      friendly_name: 'BabyCam sound level',
      unit_of_measurement: 'dB',
      state_class: 'measurement',
      icon: 'mdi:waveform',
    });
  }

  pushAll() {
    this.setCamera(this.state.camera);
    this.setNoise(this.state.noise);
    this.setLevel(this.state.level);
  }

  async push(entityId, state, attributes) {
    if (!this.token) return;
    try {
      const res = await fetch(`http://supervisor/core/api/states/${entityId}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ state: String(state), attributes }),
      });
      if (!res.ok) this.warnOnce(`Home Assistant API returned HTTP ${res.status} for ${entityId}`);
    } catch (e) {
      this.warnOnce(`Could not reach Home Assistant: ${e.message}`);
    }
  }

  warnOnce(message) {
    if (this.warned) return;
    this.warned = true;
    this.log(message);
  }
}

module.exports = HomeAssistant;
