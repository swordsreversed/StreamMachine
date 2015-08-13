var FileSource, HLSSegmenter, ProxySource, Rewind, Stream, TranscodingSource, URL, uuid, _u,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_u = require("underscore");

uuid = require("node-uuid");

URL = require("url");

Rewind = require('../rewind_buffer');

FileSource = require("../sources/file");

ProxySource = require('../sources/proxy_room');

TranscodingSource = require("../sources/transcoding");

HLSSegmenter = require("../rewind/hls_segmenter");

module.exports = Stream = (function(_super) {
  __extends(Stream, _super);

  Stream.prototype.DefaultOptions = {
    meta_interval: 32768,
    max_buffer: 4194304,
    key: null,
    seconds: 60 * 60 * 4,
    burst: 30,
    source_password: null,
    host: null,
    fallback: null,
    acceptSourceMeta: false,
    log_minutes: true,
    monitored: false,
    metaTitle: "",
    metaUrl: "",
    format: "mp3",
    preroll: "",
    preroll_key: "",
    root_route: false,
    group: null,
    bandwidth: 0,
    codec: null,
    ffmpeg_args: null
  };

  function Stream(core, key, log, opts) {
    var newsource, uri, _ref;
    this.core = core;
    this.key = key;
    this.log = log;
    this.opts = _u.defaults(opts || {}, this.DefaultOptions);
    this.sources = [];
    this.source = null;
    this._vitals = null;
    this.emitDuration = 0;
    this.STATUS = "Initializing";
    this.log.event("Stream is initializing.");
    this.log.info("Initializing RewindBuffer for master stream.");
    this.rewind = new Rewind({
      seconds: this.opts.seconds,
      burst: this.opts.burst,
      key: "master__" + this.key,
      log: this.log.child({
        module: "rewind"
      }),
      hls: (_ref = this.opts.hls) != null ? _ref.segment_duration : void 0
    });
    this.rewind.emit("source", this);
    this.rewind.on("buffer", (function(_this) {
      return function(c) {
        return _this.emit("buffer", c);
      };
    })(this));
    if (this.opts.hls != null) {
      this.rewind.hls_segmenter.on("snapshot", (function(_this) {
        return function(snap) {
          return _this.emit("hls_snapshot", snap);
        };
      })(this));
    }
    this._meta = {
      StreamTitle: this.opts.metaTitle,
      StreamUrl: ""
    };
    this.sourceMetaFunc = (function(_this) {
      return function(meta) {
        if (_this.opts.acceptSourceMeta) {
          return _this.setMetadata(meta);
        }
      };
    })(this);
    this.dataFunc = (function(_this) {
      return function(data) {
        return _this.emit("data", _u.extend({}, data, {
          meta: _this._meta
        }));
      };
    })(this);
    this.vitalsFunc = (function(_this) {
      return function(vitals) {
        _this._vitals = vitals;
        return _this.emit("vitals", vitals);
      };
    })(this);
    if (this.opts.fallback != null) {
      uri = URL.parse(this.opts.fallback);
      newsource = (function() {
        switch (uri.protocol) {
          case "file:":
            return new FileSource({
              format: this.opts.format,
              filePath: uri.path,
              logger: this.log
            });
          case "http:":
            return new ProxySource({
              format: this.opts.format,
              url: this.opts.fallback,
              fallback: true,
              logger: this.log
            });
          default:
            return null;
        }
      }).call(this);
      if (newsource) {
        newsource.on("connect", (function(_this) {
          return function() {
            return _this.addSource(newsource, function(err) {
              if (err) {
                return _this.log.error("Connection to fallback source failed.");
              } else {
                return _this.log.event("Fallback source connected.");
              }
            });
          };
        })(this));
        newsource.on("error", (function(_this) {
          return function(err) {
            return _this.log.error("Fallback source error: " + err, {
              error: err
            });
          };
        })(this));
      } else {
        this.log.error("Unable to determine fallback source type for " + this.opts.fallback);
      }
    }
  }

  Stream.prototype.config = function() {
    return this.opts;
  };

  Stream.prototype.vitals = function(cb) {
    var _vFunc;
    _vFunc = (function(_this) {
      return function(v) {
        return typeof cb === "function" ? cb(null, v) : void 0;
      };
    })(this);
    if (this._vitals) {
      return _vFunc(this._vitals);
    } else {
      return this.once("vitals", _vFunc);
    }
  };

  Stream.prototype.getHLSSnapshot = function(cb) {
    if (this.rewind.hls_segmenter) {
      return this.rewind.hls_segmenter.snapshot(cb);
    } else {
      return cb("Stream does not support HLS");
    }
  };

  Stream.prototype.getStreamKey = function(cb) {
    if (this._vitals) {
      return typeof cb === "function" ? cb(this._vitals.streamKey) : void 0;
    } else {
      return this.once("vitals", (function(_this) {
        return function() {
          return typeof cb === "function" ? cb(_this._vitals.streamKey) : void 0;
        };
      })(this));
    }
  };

  Stream.prototype.status = function() {
    var s;
    return {
      key: this.key,
      id: this.key,
      vitals: this._vitals,
      sources: (function() {
        var _i, _len, _ref, _results;
        _ref = this.sources;
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          s = _ref[_i];
          _results.push(s.info());
        }
        return _results;
      }).call(this),
      rewind: this.rewind._rStatus()
    };
  };

  Stream.prototype.setMetadata = function(opts, cb) {
    if ((opts.StreamTitle != null) || (opts.title != null)) {
      this._meta.StreamTitle = opts.StreamTitle || opts.title;
    }
    if ((opts.StreamUrl != null) || (opts.url != null)) {
      this._meta.StreamUrl = opts.StreamUrl || opts.url;
    }
    this.emit("meta", this._meta);
    return typeof cb === "function" ? cb(null, this._meta) : void 0;
  };

  Stream.prototype.addSource = function(source, cb) {
    var _ref, _ref1, _ref2;
    source.once("disconnect", (function(_this) {
      return function() {
        _this.sources = _u(_this.sources).without(source);
        if (_this.source === source) {
          if (_this.sources.length > 0) {
            _this.useSource(_this.sources[0]);
            return _this.emit("disconnect", {
              active: true,
              count: _this.sources.length,
              source: _this.source
            });
          } else {
            _this.log.alert("Source disconnected. No sources remaining.");
            _this._disconnectSource(_this.source);
            _this.source = null;
            return _this.emit("disconnect", {
              active: true,
              count: 0,
              source: null
            });
          }
        } else {
          _this.log.event("Inactive source disconnected.");
          return _this.emit("disconnect", {
            active: false,
            count: _this.sources.length,
            source: _this.source
          });
        }
      };
    })(this));
    this.sources.push(source);
    if (this.sources[0] === source || ((_ref = this.sources[0]) != null ? _ref.isFallback : void 0)) {
      this.log.event("Promoting new source to active.", {
        source: (_ref1 = typeof source.TYPE === "function" ? source.TYPE() : void 0) != null ? _ref1 : source.TYPE
      });
      return this.useSource(source, cb);
    } else {
      this.log.event("Source connected.", {
        source: (_ref2 = typeof source.TYPE === "function" ? source.TYPE() : void 0) != null ? _ref2 : source.TYPE
      });
      this.emit("add_source", source);
      return typeof cb === "function" ? cb(null) : void 0;
    }
  };

  Stream.prototype._disconnectSource = function(s) {
    s.removeListener("metadata", this.sourceMetaFunc);
    s.removeListener("data", this.dataFunc);
    return s.removeListener("vitals", this.vitalsFunc);
  };

  Stream.prototype.useSource = function(newsource, cb) {
    var alarm, old_source;
    if (cb == null) {
      cb = null;
    }
    old_source = this.source || null;
    alarm = setTimeout((function(_this) {
      return function() {
        var _ref, _ref1;
        _this.log.error("useSource failed to get switchover within five seconds.", {
          new_source: (_ref = typeof newsource.TYPE === "function" ? newsource.TYPE() : void 0) != null ? _ref : newsource.TYPE,
          old_source: (_ref1 = old_source != null ? typeof old_source.TYPE === "function" ? old_source.TYPE() : void 0 : void 0) != null ? _ref1 : old_source != null ? old_source.TYPE : void 0
        });
        return typeof cb === "function" ? cb(new Error("Failed to switch.")) : void 0;
      };
    })(this), 5000);
    return newsource.vitals((function(_this) {
      return function(err, vitals) {
        var _base, _ref, _ref1, _ref2;
        if (_this.source && old_source !== _this.source) {
          _this.log.event("Source changed while waiting for vitals.", {
            new_source: (_ref = typeof newsource.TYPE === "function" ? newsource.TYPE() : void 0) != null ? _ref : newsource.TYPE,
            old_source: (_ref1 = old_source != null ? typeof old_source.TYPE === "function" ? old_source.TYPE() : void 0 : void 0) != null ? _ref1 : old_source != null ? old_source.TYPE : void 0,
            current_source: (_ref2 = typeof (_base = _this.source).TYPE === "function" ? _base.TYPE() : void 0) != null ? _ref2 : _this.source.TYPE
          });
          return typeof cb === "function" ? cb(new Error("Source changed while waiting for vitals.")) : void 0;
        }
        if (old_source) {
          _this._disconnectSource(old_source);
        }
        _this.source = newsource;
        newsource.on("metadata", _this.sourceMetaFunc);
        newsource.on("data", _this.dataFunc);
        newsource.on("vitals", _this.vitalsFunc);
        _this.emitDuration = vitals.emitDuration;
        process.nextTick(function() {
          var _ref3, _ref4;
          _this.log.event("New source is active.", {
            new_source: (_ref3 = typeof newsource.TYPE === "function" ? newsource.TYPE() : void 0) != null ? _ref3 : newsource.TYPE,
            old_source: (_ref4 = old_source != null ? typeof old_source.TYPE === "function" ? old_source.TYPE() : void 0 : void 0) != null ? _ref4 : old_source != null ? old_source.TYPE : void 0
          });
          _this.emit("source", newsource);
          return _this.vitalsFunc(vitals);
        });
        _this.sources = _u.flatten([newsource, _u(_this.sources).without(newsource)]);
        clearTimeout(alarm);
        return typeof cb === "function" ? cb(null) : void 0;
      };
    })(this));
  };

  Stream.prototype.promoteSource = function(uuid, cb) {
    var ns;
    if (ns = _u(this.sources).find((function(_this) {
      return function(s) {
        return s.uuid === uuid;
      };
    })(this))) {
      if (ns === this.sources[0]) {
        return typeof cb === "function" ? cb(null, {
          msg: "Source is already active",
          uuid: uuid
        }) : void 0;
      } else {
        return this.useSource(ns, (function(_this) {
          return function(err) {
            if (err) {
              return typeof cb === "function" ? cb(err) : void 0;
            } else {
              return typeof cb === "function" ? cb(null, {
                msg: "Promoted source to active.",
                uuid: uuid
              }) : void 0;
            }
          };
        })(this));
      }
    } else {
      return typeof cb === "function" ? cb("Unable to find a source with that UUID on " + this.key) : void 0;
    }
  };

  Stream.prototype.configure = function(new_opts, cb) {
    var k, v, _ref;
    _ref = this.DefaultOptions;
    for (k in _ref) {
      v = _ref[k];
      if (new_opts[k] != null) {
        this.opts[k] = new_opts[k];
      }
      if (_u.isNumber(this.DefaultOptions[k])) {
        this.opts[k] = Number(this.opts[k]);
      }
    }
    if (this.key !== this.opts.key) {
      this.key = this.opts.key;
    }
    if (new_opts.metaTitle) {
      this.setMetadata({
        title: new_opts.metaTitle
      });
    }
    this.rewind.setRewind(this.opts.seconds, this.opts.burst);
    this.emit("config");
    return typeof cb === "function" ? cb(null, this.config()) : void 0;
  };

  Stream.prototype.getRewind = function(cb) {
    return this.rewind.dumpBuffer((function(_this) {
      return function(err, writer) {
        return typeof cb === "function" ? cb(null, writer) : void 0;
      };
    })(this));
  };

  Stream.prototype.destroy = function() {
    var s, _i, _len, _ref;
    _ref = this.sources;
    for (_i = 0, _len = _ref.length; _i < _len; _i++) {
      s = _ref[_i];
      s.disconnect();
    }
    this.emit("destroy");
    return true;
  };

  Stream.StreamGroup = (function(_super1) {
    __extends(StreamGroup, _super1);

    function StreamGroup(key, log) {
      this.key = key;
      this.log = log;
      this.streams = {};
      this.transcoders = {};
      this.hls_min_id = null;
      this._stream = null;
    }

    StreamGroup.prototype.addStream = function(stream) {
      var delFunc, tsource, _ref;
      if (!this.streams[stream.key]) {
        this.log.debug("SG " + this.key + ": Adding stream " + stream.key);
        this.streams[stream.key] = stream;
        if (!this._stream) {
          this._cloneStream(stream);
        }
        delFunc = (function(_this) {
          return function() {
            _this.log.debug("SG " + _this.key + ": Stream disconnected: " + stream.key);
            return delete _this.streams[stream.key];
          };
        })(this);
        stream.on("disconnect", delFunc);
        stream.on("config", (function(_this) {
          return function() {
            var tsource;
            if (stream.opts.group !== _this.key) {
              delFunc();
            }
            if (stream.opts.ffmpeg_args && !_this.transcoders[stream.key]) {
              tsource = _this._startTranscoder(stream);
              return _this.transcoders[stream.key] = tsource;
            }
          };
        })(this));
        if (stream.opts.ffmpeg_args) {
          tsource = this._startTranscoder(stream);
          this.transcoders[stream.key] = tsource;
        }
        return (_ref = stream.rewind.hls_segmenter) != null ? _ref.syncToGroup(this) : void 0;
      }
    };

    StreamGroup.prototype.status = function() {
      var s;
      return {
        id: this.key,
        sources: (function() {
          var _i, _len, _ref, _results;
          _ref = this._stream.sources;
          _results = [];
          for (_i = 0, _len = _ref.length; _i < _len; _i++) {
            s = _ref[_i];
            _results.push(s.info());
          }
          return _results;
        }).call(this)
      };
    };

    StreamGroup.prototype._startTranscoder = function(stream) {
      var tsource;
      this.log.debug("SG " + this.key + ": Setting up transcoding source for " + stream.key);
      tsource = new TranscodingSource({
        stream: this._stream,
        ffmpeg_args: stream.opts.ffmpeg_args,
        format: stream.opts.format,
        logger: stream.log
      });
      stream.addSource(tsource);
      tsource.once("disconnect", (function(_this) {
        return function() {
          _this.log.info("SG " + _this.key + ": Transcoder disconnected for " + stream.key + ". Restarting.");
          return _this._startTranscoder(stream);
        };
      })(this));
      return tsource;
    };

    StreamGroup.prototype.hlsUpdateMinSegment = function(id) {
      var prev;
      if (!this.hls_min_id || id > this.hls_min_id) {
        prev = this.hls_min_id;
        this.hls_min_id = id;
        this.emit("hls_update_min_segment", id);
        return this.log.debug("New HLS min segment id: " + id + " (Previously: " + prev + ")");
      }
    };

    StreamGroup.prototype._cloneStream = function(stream) {
      return this._stream = new Stream(null, this.key, this.log.child({
        stream: "_" + this.key
      }), _u.extend({}, stream.opts, {
        seconds: 30
      }));
    };

    return StreamGroup;

  })(require("events").EventEmitter);

  return Stream;

})(require('events').EventEmitter);

//# sourceMappingURL=stream.js.map
