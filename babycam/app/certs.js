'use strict';
// Let's Encrypt certificate via Cloudflare DNS-01, plus a DNS-only A record
// pointing the BabyCam hostname at this machine's LAN IP.

const fs = require('fs');
const path = require('path');
const { X509Certificate } = require('crypto');
const acme = require('acme-client');

const RENEW_WHEN_DAYS_LEFT = 30;

function cloudflare(token) {
  async function api(method, route, body) {
    const res = await fetch(`https://api.cloudflare.com/client/v4${route}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await res.json().catch(() => ({}));
    if (!json.success) {
      const errors = (json.errors || []).map((e) => e.message).join('; ') || `HTTP ${res.status}`;
      throw new Error(`Cloudflare ${method} ${route.split('?')[0]}: ${errors}`);
    }
    return json.result;
  }

  // babycam.home.example.com -> tries home.example.com... until a zone matches.
  async function zoneFor(name) {
    const labels = name.split('.');
    for (let i = 0; i < labels.length - 1; i++) {
      const candidate = labels.slice(i).join('.');
      const zones = await api('GET', `/zones?name=${encodeURIComponent(candidate)}`);
      if (zones.length) return zones[0].id;
    }
    throw new Error(`No Cloudflare zone found for ${name}. Check the token has Zone:Read and DNS:Edit for your domain.`);
  }

  return {
    async createTxt(name, content) {
      const zone = await zoneFor(name);
      const record = await api('POST', `/zones/${zone}/dns_records`, { type: 'TXT', name, content, ttl: 60 });
      return { zone, id: record.id };
    },

    async deleteRecord({ zone, id }) {
      await api('DELETE', `/zones/${zone}/dns_records/${id}`);
    },

    async upsertLocalRecord(name, ip, log) {
      const zone = await zoneFor(name);
      const existing = await api('GET', `/zones/${zone}/dns_records?name=${encodeURIComponent(name)}`);
      const other = existing.find((r) => r.type !== 'A');
      if (other) {
        throw new Error(`${name} already has a ${other.type} record (maybe a tunnel route). ` +
          'Pick a different domain for BabyCam, or delete that record.');
      }
      const body = { type: 'A', name, content: ip, ttl: 300, proxied: false, comment: 'BabyCam (local network only)' };
      const a = existing.find((r) => r.type === 'A');
      if (a && a.content === ip && !a.proxied) return;
      if (a) await api('PUT', `/zones/${zone}/dns_records/${a.id}`, body);
      else await api('POST', `/zones/${zone}/dns_records`, body);
      log(`DNS: ${name} -> ${ip} (DNS only, not proxied)`);
    },
  };
}

function daysLeft(certPem) {
  const validTo = new Date(new X509Certificate(certPem).validTo);
  return (validTo - Date.now()) / 86_400_000;
}

async function ensureCertificate({ domain, email, token, dataDir, log }) {
  const dir = path.join(dataDir, 'certs');
  fs.mkdirSync(dir, { recursive: true });
  const certFile = path.join(dir, 'fullchain.pem');
  const keyFile = path.join(dir, 'privkey.pem');
  const domainFile = path.join(dir, 'domain');
  const accountFile = path.join(dir, 'account.pem');

  if (fs.existsSync(certFile) && fs.existsSync(keyFile) &&
      fs.existsSync(domainFile) && fs.readFileSync(domainFile, 'utf8') === domain) {
    const cert = fs.readFileSync(certFile, 'utf8');
    const left = daysLeft(cert);
    if (left > RENEW_WHEN_DAYS_LEFT) {
      return { cert, key: fs.readFileSync(keyFile, 'utf8'), renewed: false };
    }
    log(`Certificate expires in ${Math.floor(left)} days; renewing.`);
  } else {
    log(`Requesting a Let's Encrypt certificate for ${domain} (takes about a minute)…`);
  }

  let accountKey;
  if (fs.existsSync(accountFile)) {
    accountKey = fs.readFileSync(accountFile);
  } else {
    accountKey = await acme.crypto.createPrivateKey();
    fs.writeFileSync(accountFile, accountKey);
  }

  const cf = cloudflare(token);
  const records = new Map();
  const client = new acme.Client({ directoryUrl: acme.directory.letsencrypt.production, accountKey });
  const [key, csr] = await acme.crypto.createCsr({ commonName: domain, altNames: [domain] });

  const cert = await client.auto({
    csr,
    email,
    termsOfServiceAgreed: true,
    challengePriority: ['dns-01'],
    challengeCreateFn: async (authz, challenge, keyAuthorization) => {
      const name = `_acme-challenge.${authz.identifier.value}`;
      records.set(keyAuthorization, await cf.createTxt(name, keyAuthorization));
    },
    challengeRemoveFn: async (authz, challenge, keyAuthorization) => {
      const record = records.get(keyAuthorization);
      if (record) await cf.deleteRecord(record).catch(() => {});
    },
  });

  fs.writeFileSync(certFile, cert);
  fs.writeFileSync(keyFile, key);
  fs.writeFileSync(domainFile, domain);
  log('Certificate ready.');
  return { cert, key: key.toString(), renewed: true };
}

module.exports = { ensureCertificate, cloudflare };
