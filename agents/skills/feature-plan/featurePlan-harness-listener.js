#!/usr/bin/env node
/**
 * featurePlan-harness-listener.js — WebSocket server for interactive feature planning
 *
 * The harness (Claude Code, Copilot, Pi) launches this when opening a featurePlan HTML.
 * It establishes a WebSocket server and listens for user questions, forwards them to
 * an AI agent, and sends patch operations back to the page.
 *
 * Usage (from a skill or command):
 *   const listener = require('./featurePlan-harness-listener');
 *   const server = listener.createServer(3001, { aiAgent: myAIFn });
 *   // Pass ?socket-port=3001 to the HTML
 */

const WebSocket = require('ws');
const { createPatch, createAddPatch } = require('./featurePlan-inject');

class FeaturePlanListener {
  constructor(port, options = {}) {
    this.port = port;
    this.aiAgent = options.aiAgent || this.defaultAIAgent;
    this.server = null;
    this.clients = [];
  }

  start() {
    return new Promise((resolve, reject) => {
      try {
        this.server = new WebSocket.Server({ port: this.port });

        this.server.on('connection', (ws) => {
          console.log(`[featurePlan] Client connected from ${ws._socket.remoteAddress}`);
          this.clients.push(ws);

          ws.on('message', (data) => {
            this.handleMessage(ws, data);
          });

          ws.on('close', () => {
            console.log('[featurePlan] Client disconnected');
            this.clients = this.clients.filter(c => c !== ws);
          });

          ws.on('error', (err) => {
            console.error('[featurePlan] WebSocket error:', err);
          });
        });

        this.server.on('error', (err) => {
          reject(err);
        });

        this.server.on('listening', () => {
          console.log(`[featurePlan] WebSocket server listening on ws://localhost:${this.port}`);
          resolve();
        });
      } catch (err) {
        reject(err);
      }
    });
  }

  stop() {
    return new Promise((resolve) => {
      if (this.server) {
        this.server.close(() => {
          console.log('[featurePlan] WebSocket server stopped');
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  async handleMessage(ws, data) {
    try {
      const msg = JSON.parse(data);

      if (msg.type === 'question') {
        const { section, question, plan } = msg;
        console.log(`[featurePlan] Question from user (section: ${section}): ${question.substring(0, 60)}...`);

        // Forward to AI agent
        const result = await this.aiAgent({
          section,
          question,
          plan,
          currentTimestamp: new Date().toISOString()
        });

        if (result && result.response) {
          // Send response text
          this.broadcast({
            type: 'response',
            section,
            text: result.response
          });

          // Send any patches
          if (Array.isArray(result.patches)) {
            result.patches.forEach(patch => {
              this.broadcast(patch);
            });
          }
        }
      } else {
        console.warn('[featurePlan] Unknown message type:', msg.type);
      }
    } catch (err) {
      console.error('[featurePlan] Error processing message:', err);
      ws.send(JSON.stringify({
        type: 'error',
        message: err.message
      }));
    }
  }

  broadcast(msg) {
    const payload = JSON.stringify(msg);
    this.clients.forEach(client => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(payload);
      }
    });
  }

  // Default AI agent (no-op, just echoes the question)
  async defaultAIAgent(input) {
    const { section, question } = input;
    return {
      response: `Clarification on "${section}": ${question}. (No AI configured; configure via options.aiAgent.)`
    };
  }
}

function createServer(port, options) {
  return new FeaturePlanListener(port, options);
}

// For Node.js usage
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FeaturePlanListener,
    createServer
  };
}
