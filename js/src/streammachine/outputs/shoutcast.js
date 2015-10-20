var BaseOutput, Shoutcast, icecast, _u,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_u = require('underscore');

icecast = require("icecast");

BaseOutput = require("./base");

module.exports = Shoutcast = (function(_super) {
  __extends(Shoutcast, _super);

  function Shoutcast(stream, opts) {
    this.stream = stream;
    this.opts = opts;
    this.disconnected = false;
    this.id = null;
    Shoutcast.__super__.constructor.call(this, "shoutcast");
    this.pump = true;
    this._lastMeta = null;
    if (this.opts.req && this.opts.res) {
      this.client.offsetSecs = this.opts.req.param("offset") || -1;
      this.client.meta_int = this.stream.opts.meta_interval;
      this.opts.res.chunkedEncoding = false;
      this.opts.res.useChunkedEncodingByDefault = false;
      this.headers = {
        "Content-Type": this.stream.opts.format === "mp3" ? "audio/mpeg" : this.stream.opts.format === "aac" ? "audio/aacp" : "unknown",
        "icy-name": this.stream.StreamTitle,
        "icy-url": this.stream.StreamUrl,
        "icy-metaint": this.client.meta_int
      };
      this.opts.res.writeHead(200, this.headers);
      this.opts.res._send('');
      this.stream.startSession(this.client, (function(_this) {
        return function(err, session_id) {
          _this.client.session_id = session_id;
          return process.nextTick(function() {
            return _this._startAudio(true);
          });
        };
      })(this));
    } else if (this.opts.socket) {
      this.pump = false;
      process.nextTick((function(_this) {
        return function() {
          return _this._startAudio(false);
        };
      })(this));
    }
    this.socket.on("end", (function(_this) {
      return function() {
        return _this.disconnect();
      };
    })(this));
    this.socket.on("close", (function(_this) {
      return function() {
        return _this.disconnect();
      };
    })(this));
    this.socket.on("error", (function(_this) {
      return function() {
        return _this.disconnect();
      };
    })(this));
  }

  Shoutcast.prototype._startAudio = function(initial) {
    this.ice = new icecast.Writer(this.client.bytesToNextMeta || this.client.meta_int);
    this.ice.metaint = this.client.meta_int;
    delete this.client.bytesToNextMeta;
    if (initial && this.stream.preroll && !this.opts.req.param("preskip")) {
      return this.stream.preroll.pump(this.client, this.socket, this.ice, (function(_this) {
        return function(err, impression_cb) {
          return _this.connectToStream(impression_cb);
        };
      })(this));
    } else {
      return this.connectToStream();
    }
  };

  Shoutcast.prototype.disconnect = function() {
    var _ref, _ref1, _ref2, _ref3;
    if (!this.disconnected) {
      this.disconnected = true;
      if ((_ref = this.ice) != null) {
        _ref.unpipe();
      }
      if ((_ref1 = this.source) != null) {
        _ref1.disconnect();
      }
      if (!((_ref2 = this.socket) != null ? _ref2.destroyed : void 0)) {
        return (_ref3 = this.socket) != null ? _ref3.end() : void 0;
      }
    }
  };

  Shoutcast.prototype.prepForHandoff = function(cb) {
    this.client.bytesToNextMeta = this.ice._parserBytesLeft;
    delete this.client.offsetSecs;
    return typeof cb === "function" ? cb() : void 0;
  };

  Shoutcast.prototype.connectToStream = function(impression_cb) {
    if (!this.disconnected) {
      return this.stream.listen(this, {
        offsetSecs: this.client.offsetSecs,
        offset: this.client.offset,
        pump: this.pump,
        startTime: this.opts.startTime,
        impressionCB: impression_cb
      }, (function(_this) {
        return function(err, source) {
          var _ref;
          _this.source = source;
          if (err) {
            if (_this.opts.res != null) {
              _this.opts.res.status(500).end(err);
            } else {
              if ((_ref = _this.socket) != null) {
                _ref.end();
              }
            }
            return false;
          }
          _this.client.offset = _this.source.offset();
          _this.source.onFirstMeta(function(err, meta) {
            if (meta) {
              return _this.ice.queue(meta);
            }
          });
          _this.metaFunc = function(data) {
            if (!(_this._lastMeta && _u(data).isEqual(_this._lastMeta))) {
              _this.ice.queue(data);
              return _this._lastMeta = data;
            }
          };
          _this.ice.pipe(_this.socket);
          _this.source.pipe(_this.ice);
          return _this.source.on("meta", _this.metaFunc);
        };
      })(this));
    }
  };

  return Shoutcast;

})(BaseOutput);

//# sourceMappingURL=shoutcast.js.map
