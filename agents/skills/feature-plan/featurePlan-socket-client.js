class FeaturePlanSocket {
  constructor(port) {
    this.port = port;
    this.socket = null;
    this.connected = false;
    this.queue = [];
    this.listeners = {};
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 10;
    this.reconnectDelay = 2000;
    this.connect();
  }

  connect() {
    try {
      this.socket = new WebSocket(`ws://localhost:${this.port}`);

      this.socket.onopen = () => {
        this.connected = true;
        this.reconnectAttempts = 0;
        this.emit('connect');
        this.flushQueue();
      };

      this.socket.onmessage = (e) => {
        try {
          const msg = JSON.parse(e.data);
          this.handleMessage(msg);
        } catch (err) {
          console.error('Failed to parse WebSocket message:', err, e.data);
        }
      };

      this.socket.onerror = (err) => {
        console.error('WebSocket error:', err);
        this.emit('error', err);
      };

      this.socket.onclose = () => {
        this.connected = false;
        this.emit('disconnect');
        this.attemptReconnect();
      };
    } catch (err) {
      console.error('Failed to create WebSocket:', err);
      this.attemptReconnect();
    }
  }

  attemptReconnect() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      setTimeout(() => {
        console.log(`Reconnecting (attempt ${this.reconnectAttempts}/${this.maxReconnectAttempts})...`);
        this.connect();
      }, this.reconnectDelay);
    } else {
      console.error('Max reconnection attempts reached. Interactive mode disabled.');
      this.emit('fatal-error', 'Could not connect to harness');
    }
  }

  send(msg) {
    if (typeof msg === 'object') {
      msg = JSON.stringify(msg);
    }
    if (this.connected && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(msg);
    } else {
      this.queue.push(msg);
      if (!this.connected) {
        console.warn('WebSocket not connected. Message queued.');
      }
    }
  }

  sendQuestion(section, question, currentPlan) {
    const msg = {
      type: 'question',
      section,
      question,
      plan: currentPlan
    };
    this.send(msg);
  }

  handleMessage(msg) {
    const { type } = msg;
    if (type === 'response') {
      this.emit('response', msg);
    } else if (type === 'patch') {
      this.emit('patch', msg);
    } else if (type === 'ack') {
      this.emit('ack', msg);
    } else {
      console.warn('Unknown message type:', type, msg);
    }
  }

  flushQueue() {
    while (this.queue.length > 0 && this.connected && this.socket.readyState === WebSocket.OPEN) {
      const msg = this.queue.shift();
      this.socket.send(msg);
    }
  }

  on(event, callback) {
    if (!this.listeners[event]) {
      this.listeners[event] = [];
    }
    this.listeners[event].push(callback);
  }

  off(event, callback) {
    if (this.listeners[event]) {
      this.listeners[event] = this.listeners[event].filter(cb => cb !== callback);
    }
  }

  emit(event, data) {
    if (this.listeners[event]) {
      this.listeners[event].forEach(cb => {
        try {
          cb(data);
        } catch (err) {
          console.error(`Error in listener for ${event}:`, err);
        }
      });
    }
  }

  isConnected() {
    return this.connected;
  }

  close() {
    if (this.socket) {
      this.socket.close();
    }
  }
}

// Export for Node (if used in tests)
if (typeof module !== 'undefined' && module.exports) {
  module.exports = FeaturePlanSocket;
}
